import AppKit
import CryptoKit
import SwiftUI

struct ReleaseVersion: Comparable {
    let parts: [Int]

    init?(_ string: String) {
        let value = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              fields.compactMap({ Int($0) }).count == 3 else { return nil }
        parts = fields.compactMap { Int($0) }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }
}

struct AppRelease: Equatable {
    let version: String
    let downloadURL: URL
    let sha256: String

    static func parse(_ data: Data, currentVersion: String) throws -> AppRelease? {
        struct Response: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let digest: String?
            }
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let current = ReleaseVersion(currentVersion) else { throw UpdateError.invalidVersion }
        guard !response.draft, !response.prerelease,
              let latest = ReleaseVersion(response.tag_name), latest > current else { return nil }
        guard let asset = response.assets.first(where: { $0.name == "MenuLauncher.zip" }),
              asset.browser_download_url.scheme == "https",
              asset.browser_download_url.host == "github.com",
              asset.browser_download_url.user == nil,
              asset.browser_download_url.port == nil,
              asset.browser_download_url.path == "/ykai55/menubar-launcher/releases/download/\(response.tag_name)/MenuLauncher.zip",
              let digest = asset.digest, digest.hasPrefix("sha256:") else { throw UpdateError.invalidRelease }
        let hash = String(digest.dropFirst(7)).lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw UpdateError.invalidRelease }
        return AppRelease(version: response.tag_name.hasPrefix("v") ? String(response.tag_name.dropFirst()) : response.tag_name,
                          downloadURL: asset.browser_download_url, sha256: hash)
    }
}

enum UpdateError: Error {
    case invalidVersion, invalidRelease, checksum, invalidBundle, location, helper, command, http(Int)

    func message(_ language: AppLanguage) -> String {
        switch self {
        case .invalidVersion: return language.text("This build has no release version.", "当前构建没有有效的版本号。")
        case .invalidRelease: return language.text("The release is missing a verified installation package.", "新版本缺少可校验的安装包。")
        case .checksum: return language.text("The download failed its SHA-256 check. Please retry.", "安装包校验失败，请重试。")
        case .invalidBundle: return language.text("The downloaded app failed validation.", "下载的应用未通过验证。")
        case .location: return language.text("Move MenuLauncher to a writable Applications folder, or update with Homebrew.", "请将 MenuLauncher 移到有写入权限的“应用程序”目录，或通过 Homebrew 更新。")
        case .helper: return language.text("The installer could not start. Please retry.", "安装程序未能启动，请重试。")
        case .command: return language.text("Installation failed. The previous app has been kept.", "安装失败，已保留原应用。")
        case .http(let code): return language.text("The update server returned HTTP \(code). Please try later.", "更新服务器返回 HTTP \(code)，请稍后重试。")
        }
    }
}

/// Separate from LauncherModel's published state so checks never rebuild the app grid.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var available: AppRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    var onNotice: ((String, Bool) -> Void)?
    var onReadyToRestart: (() -> Void)?
    private var nextCheck = Date.distantPast
    private let currentVersion: String
    private let fetch: () async throws -> Data

    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         fetch: @escaping () async throws -> Data = AppUpdater.fetchLatest) {
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    static func fetchLatest() async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/ykai55/menubar-launcher/releases/latest")!)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MenuLauncher", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTP(response)
        return data
    }

    static func validateHTTP(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidRelease }
        guard response.statusCode == 200 else { throw UpdateError.http(response.statusCode) }
    }

    func check(force: Bool = false, language: AppLanguage = .system, now: Date = Date()) async {
        guard !isChecking, !isInstalling, force || now >= nextCheck else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            available = try AppRelease.parse(try await fetch(), currentVersion: currentVersion)
            nextCheck = now.addingTimeInterval(6 * 60 * 60)
            if force {
                onNotice?(available.map { language.text("Version \($0.version) is available. Click Upgrade in the top-right corner.", "发现新版本 \($0.version)，点击右上角“升级”即可更新。") }
                    ?? language.text("You're up to date (\(currentVersion)).", "当前已是最新版本（\(currentVersion)）。"), false)
            }
        } catch {
            nextCheck = now.addingTimeInterval(15 * 60)
            if force { onNotice?(describe(error, language), true) }
        }
    }

    func install(language: AppLanguage) async {
        guard let release = available, !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        var staging: URL?
        var handedOff = false
        defer { if !handedOff, let staging { try? FileManager.default.removeItem(at: staging) } }
        do {
            let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
            let directory = try UpdateInstaller.makeStagingDirectory(target: target)
            staging = directory
            var request = URLRequest(url: release.downloadURL)
            request.timeoutInterval = 120
            let (download, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: download) }
            try Self.validateHTTP(response)
            let prepared = try await Task.detached {
                try UpdateInstaller.prepare(download: download, release: release, directory: directory)
            }.value
            let helper = directory.appendingPathComponent("installer")
            guard let executable = Bundle.main.executableURL else { throw UpdateError.helper }
            try FileManager.default.copyItem(at: executable, to: helper)
            let plan = UpdateInstaller.Plan(target: target, staged: prepared, parentPID: ProcessInfo.processInfo.processIdentifier,
                                            language: language.resolved())
            let planURL = directory.appendingPathComponent("plan.json")
            try JSONEncoder().encode(plan).write(to: planURL, options: .atomic)
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--install-update", planURL.path]
            try process.run()
            let ready = directory.appendingPathComponent("ready")
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: ready.path) { break }
                guard process.isRunning else { throw UpdateError.helper }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard FileManager.default.fileExists(atPath: ready.path), process.isRunning else {
                if process.isRunning { process.terminate() }
                throw UpdateError.helper
            }
            handedOff = true
            onReadyToRestart?()
        } catch {
            onNotice?(describe(error, language), true)
        }
    }

    private func describe(_ error: Error, _ language: AppLanguage) -> String {
        (error as? UpdateError)?.message(language) ?? error.localizedDescription
    }
}

struct UpdateButton: View {
    @ObservedObject var updater: AppUpdater
    @Environment(\.launcherLanguage) private var language

    var body: some View {
        if let release = updater.available {
            Button {
                Task { await updater.install(language: language) }
            } label: {
                HStack(spacing: 4) {
                    if updater.isInstalling {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text(updater.isInstalling ? language.text("Updating…", "升级中…") : language.text("Upgrade", "升级"))
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain).focusable(false)
            .disabled(updater.isInstalling)
            .fixedSize()
            .help(language.text("Install \(release.version) and restart", "安装 \(release.version) 并重启"))
            .accessibilityIdentifier("upgradeButton")
        }
    }
}
