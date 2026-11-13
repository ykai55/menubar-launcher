import Foundation
import CoreServices

/// Owned and operated on the main queue; filesystem traversal remains in AppIndex's worker.
@MainActor
final class AppDirectoryMonitor {
    private let roots: [String]
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var watchedPaths = Set<String>()
    private var restartNeeded = false

    init(paths: [String] = AppIndex.searchDirs, debounce: TimeInterval = 1,
         onChange: @escaping () -> Void) {
        roots = paths.map(Self.physicalPath)
        self.debounce = debounce
        self.onChange = onChange
    }

    private static func physicalPath(_ path: String) -> String {
        // FSEvents uses /private/var, while Foundation may preserve /var even
        // after resolvingSymlinksInPath. Resolve the existing ancestor with realpath.
        var url = URL(fileURLWithPath: path)
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            missing.append(url.lastPathComponent)
            url.deleteLastPathComponent()
        }
        if let resolved = realpath(url.path, nil) {
            url = URL(fileURLWithPath: String(cString: resolved))
            free(resolved)
        }
        for component in missing.reversed() { url.appendPathComponent(component) }
        return url.path
    }

    private var existingWatchPaths: Set<String> {
        // Missing roots use the nearest existing ancestor until they appear.
        Set(roots.map { path -> String in
            var url = URL(fileURLWithPath: path)
            while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
                url.deleteLastPathComponent()
            }
            return url.path
        })
    }

    @discardableResult
    func start() -> Bool {
        stop()
        watchedPaths = existingWatchPaths
        restartNeeded = false
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<AppDirectoryMonitor>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(paths, to: NSArray.self) as! [String]
            MainActor.assumeIsolated {
                for index in 0..<count {
                    monitor.receive(path: names[index], flags: flags[index])
                }
            }
        }, &context, Array(watchedPaths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.25, flags) else {
            Diagnostics.record("scan.watch_failed")
            return false
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            stop()
            Diagnostics.record("scan.watch_failed")
            return false
        }
        Diagnostics.record("scan.watch_started", ["roots": String(roots.count)])
        return true
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        pending?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func receive(path: String, flags: FSEventStreamEventFlags) {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            restartNeeded = true
        }
        let recovery = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0
        guard recovery || roots.contains(where: {
            path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/")
        }) else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                // RootChanged invalidates the old path watch. Rebind before the
                // rescan, including when a previously missing root now exists.
                if self.stream != nil &&
                    (self.restartNeeded || self.watchedPaths != self.existingWatchPaths) {
                    self.start()
                }
                Diagnostics.record("scan.directory_changed")
                self.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
