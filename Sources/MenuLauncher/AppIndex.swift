import AppKit

struct AppItem: Identifiable {
    var id: String { url.path }
    let name: String
    let url: URL
    let bundleID: String?
    let icon: NSImage
    /// 用于匹配的关键词：小写原名、拼音全拼、首字母缩写
    let keywords: [String]
    /// 名字里各个单词（英文按空格、中文按拼音），用于单词前缀匹配
    let words: [String]
    /// 排序用的键：英文为小写原名，中文为拼音，保证"微信"排在 W 组
    let sortKey: String
    /// 所在分组：A–Z，其他字符归入 #
    var section: String {
        guard let c = sortKey.unicodeScalars.first, ("a"..."z").contains(c) else { return "#" }
        return String(c).uppercased()
    }
}

enum AppIndex {
    static let searchDirs = [
        "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices/Applications",
        // Safari 实际装在这里，/Applications 下的 Safari.app 是带 hidden 标志的符号链接，会被跳过
        "/System/Cryptexes/App/System/Applications",
        NSHomeDirectory() + "/Applications",
    ]

    /// icons 为 false 时不生成图标（命令行列应用时用，快很多）
    static func scan(icons: Bool = true) -> [AppItem] {
        let fm = FileManager.default
        var seen = Set<String>()
        var items: [AppItem] = []

        for dir in searchDirs {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: dir),
                                        includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                guard url.pathExtension == "app" else { continue }
                let path = url.resolvingSymlinksInPath().path
                guard seen.insert(path).inserted else { continue }

                var name = fm.displayName(atPath: url.path)
                if name.hasSuffix(".app") { name = String(name.dropLast(4)) }

                let icon = icons ? thumbnail(NSWorkspace.shared.icon(forFile: url.path)) : NSImage()

                // 显示的是本地化名字（系统设置），也要能用原始名字搜（System Settings）：
                // 文件名和 Info.plist 里未本地化的 CFBundleName / CFBundleDisplayName 都算别名
                let bundle = Bundle(url: url)
                let info = bundle?.infoDictionary
                let aliases = [url.deletingPathExtension().lastPathComponent,
                               info?["CFBundleDisplayName"] as? String, info?["CFBundleName"] as? String]
                    .compactMap { $0 }
                let terms = searchTerms(for: name, aliases: aliases)
                items.append(AppItem(name: name, url: url, bundleID: bundle?.bundleIdentifier, icon: icon,
                                     keywords: terms.keywords, words: terms.words, sortKey: terms.sortKey))
            }
        }
        return items.sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
    }

    /// 系统图标是多尺寸的 icns，每次绘制都要挑尺寸、缩放。扫描时一次性栅格化成 @2x 位图，滚动时直接贴图
    static func thumbnail(_ icon: NSImage, side: CGFloat = 40) -> NSImage {
        let px = Int(side * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return icon }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    static func searchTerms(for name: String, aliases: [String] = []) -> (keywords: [String], words: [String], sortKey: String) {
        let lower = name.lowercased()
        var words: [String] = []
        var keywords: [String] = []
        var sortKey = lower

        var seen = Set<String>()
        for n in [name] + aliases {
            let l = n.lowercased()
            guard !l.isEmpty, seen.insert(l).inserted else { continue }
            let w = l.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." }).map(String.init)
            keywords += [l, l.replacingOccurrences(of: " ", with: "")]
            if w.count > 1 {
                keywords.append(w.compactMap(\.first).map(String.init).joined()) // Visual Studio Code -> vsc
            }
            words += w
        }

        // 含非 ASCII（中文等）时转拼音：微信 -> weixin / wx
        if name.unicodeScalars.contains(where: { !$0.isASCII }) {
            let s = NSMutableString(string: name) as CFMutableString
            CFStringTransform(s, nil, kCFStringTransformToLatin, false)
            CFStringTransform(s, nil, kCFStringTransformStripDiacritics, false)
            let latin = (s as String).lowercased()
            let pinyinWords = latin.split(separator: " ").map(String.init)
            keywords.append(pinyinWords.joined())
            keywords.append(pinyinWords.compactMap(\.first).map(String.init).joined())
            words += pinyinWords
            sortKey = latin
        }
        return (keywords, words, sortKey)
    }
}
