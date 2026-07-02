import AppKit
import Foundation

@MainActor
final class UpdateManager: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(String)
        case downloading
        case installing
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "尚未检查"
            case .checking:
                return "正在检查更新"
            case .upToDate:
                return "已是最新版本"
            case .updateAvailable(let version):
                return "发现新版本 \(version)"
            case .downloading:
                return "正在下载并准备安装"
            case .installing:
                return "正在安装更新并重启应用"
            case .failed(let message):
                return "更新失败：\(message)"
            }
        }
    }

    @Published var autoCheckEnabled: Bool {
        didSet {
            defaults.set(autoCheckEnabled, forKey: autoCheckKey)
        }
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var latestRelease: GitHubRelease?

    private let defaults: UserDefaults
    private let autoCheckKey = "updates.autoCheckEnabled.v1"
    private var didRunStartupCheck = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoCheckEnabled = defaults.object(forKey: autoCheckKey) as? Bool ?? true
    }

    func checkOnStartupIfNeeded() async {
        guard autoCheckEnabled, !didRunStartupCheck else { return }
        didRunStartupCheck = true
        await checkForUpdates(silent: true)
    }

    func checkForUpdates(silent: Bool = false) async {
        status = .checking

        do {
            let release = try await fetchLatestRelease()
            latestRelease = release

            if isVersion(release.versionString, newerThan: AppVersion.current) {
                status = .updateAvailable(release.versionString)
            } else {
                status = silent ? .idle : .upToDate
            }
        } catch {
            status = silent ? .idle : .failed(error.localizedDescription)
        }
    }

    func downloadAndInstallUpdate() async {
        guard let latestRelease else {
            await checkForUpdates()
            guard case .updateAvailable = status else { return }
            return await downloadAndInstallUpdate()
        }

        guard let asset = latestRelease.macUpdateAsset else {
            NSWorkspace.shared.open(AppVersion.releasesURL)
            status = .failed("这个 release 里没有 macOS .app.zip 更新包")
            return
        }

        do {
            status = .downloading
            let packageURL = try await download(asset: asset)
            let appURL = try prepareAppBundle(from: packageURL)
            status = .installing
            try launchInstaller(newAppURL: appURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(AppVersion.releasesURL)
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: AppVersion.latestReleaseAPIURL)
        request.setValue("417ssh/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw UpdateError.httpStatus(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func download(asset: GitHubRelease.Asset) async throws -> URL {
        guard let assetURL = URL(string: asset.browserDownloadURL) else {
            throw UpdateError.invalidAssetURL
        }

        var request = URLRequest(url: assetURL)
        request.setValue("417ssh/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw UpdateError.httpStatus(httpResponse.statusCode)
        }

        let updatesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("417ssh-updates", isDirectory: true)
        try FileManager.default.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)

        let destinationURL = updatesDirectory.appendingPathComponent(asset.name)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func prepareAppBundle(from packageURL: URL) throws -> URL {
        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("417ssh-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try extractZip(packageURL, to: stagingURL)

        guard let appURL = findAppBundle(in: stagingURL) else {
            throw UpdateError.appBundleNotFound
        }
        return appURL
    }

    private func extractZip(_ packageURL: URL, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: "/usr/bin/ditto") {
            try runProcess(
                executable: "/usr/bin/ditto",
                arguments: ["-x", "-k", packageURL.path, destinationURL.path]
            )
            return
        }

        try runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-q", packageURL.path, "-d", destinationURL.path]
        )
    }

    private func findAppBundle(in directoryURL: URL) -> URL? {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        var candidates: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "app" else { continue }
            candidates.append(fileURL)
            enumerator.skipDescendants()
        }

        return candidates.first { $0.lastPathComponent == "417ssh.app" } ?? candidates.first
    }

    private func launchInstaller(newAppURL: URL) throws {
        let targetAppURL = Bundle.main.bundleURL.standardizedFileURL
        guard targetAppURL.pathExtension == "app" else {
            throw UpdateError.notRunningFromAppBundle
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("417ssh-install-\(UUID().uuidString).sh")
        let stagingURL = newAppURL.deletingLastPathComponent()
        let targetParentURL = targetAppURL.deletingLastPathComponent()
        let processIdentifier = ProcessInfo.processInfo.processIdentifier

        let script = """
        #!/bin/bash
        set -u

        APP_PID=\(processIdentifier)
        NEW_APP=\(shellQuoted(newAppURL.path))
        TARGET_APP=\(shellQuoted(targetAppURL.path))
        TARGET_PARENT=\(shellQuoted(targetParentURL.path))
        STAGING_DIR=\(shellQuoted(stagingURL.path))
        BACKUP_APP="${TARGET_APP}.previous-update"

        while /bin/kill -0 "$APP_PID" 2>/dev/null; do
          /bin/sleep 0.2
        done

        if ! /bin/mkdir -p "$TARGET_PARENT"; then
          /usr/bin/open "$TARGET_APP" || true
          exit 1
        fi

        /bin/rm -rf "$BACKUP_APP"
        if [ -d "$TARGET_APP" ]; then
          if ! /bin/mv "$TARGET_APP" "$BACKUP_APP"; then
            /usr/bin/open "$TARGET_APP" || true
            exit 1
          fi
        fi

        if /usr/bin/ditto "$NEW_APP" "$TARGET_APP"; then
          /bin/rm -rf "$BACKUP_APP"
          /bin/rm -rf "$STAGING_DIR"
          /usr/bin/open "$TARGET_APP"
          /bin/rm -f "$0"
          exit 0
        fi

        if [ -d "$BACKUP_APP" ] && [ ! -d "$TARGET_APP" ]; then
          /bin/mv "$BACKUP_APP" "$TARGET_APP"
        fi
        /usr/bin/open "$TARGET_APP" || true
        exit 1
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    private func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.processFailed(URL(fileURLWithPath: executable).lastPathComponent, errorMessage ?? "")
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = versionComponents(candidate)
        let rhs = versionComponents(current)
        let count = max(lhs.count, rhs.count, 3)

        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left > right
            }
        }

        return false
    }

    private func versionComponents(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split { !$0.isNumber }
            .compactMap { Int($0) }
    }
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let htmlURL: String
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
        case assets
    }

    var versionString: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    var macUpdateAsset: Asset? {
        assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".zip")
                && (name.contains("mac") || name.contains("darwin") || name.contains("app"))
                && name.contains("417ssh")
        } ?? assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".zip") && (name.contains("mac") || name.contains("darwin"))
        } ?? assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".zip") && name.contains("417ssh")
        }
    }
}

private enum UpdateError: LocalizedError {
    case httpStatus(Int)
    case invalidAssetURL
    case appBundleNotFound
    case notRunningFromAppBundle
    case processFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            if status == 404 {
                return "GitHub 返回 HTTP 404。请确认仓库和 Releases 是 public，并且已经有 latest release。"
            }
            return "GitHub 返回 HTTP \(status)"
        case .invalidAssetURL:
            return "更新包下载地址无效"
        case .appBundleNotFound:
            return "更新包里没有找到 417ssh.app"
        case .notRunningFromAppBundle:
            return "当前不是从 417ssh.app 运行，不能自动替换应用文件"
        case .processFailed(let command, let message):
            if message.isEmpty {
                return "\(command) 执行失败"
            }
            return "\(command) 执行失败：\(message)"
        }
    }
}
