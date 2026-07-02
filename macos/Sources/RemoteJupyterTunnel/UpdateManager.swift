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
        case downloaded(URL)
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
                return "正在下载安装包"
            case .downloaded:
                return "安装包已打开"
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

    func downloadAndOpenInstaller() async {
        guard let latestRelease else {
            await checkForUpdates()
            guard case .updateAvailable = status else { return }
            return await downloadAndOpenInstaller()
        }

        guard let asset = latestRelease.macInstallerAsset else {
            NSWorkspace.shared.open(AppVersion.releasesURL)
            status = .failed("这个 release 里没有 macOS .dmg 安装包")
            return
        }

        do {
            status = .downloading
            let installerURL = try await download(asset: asset)
            NSWorkspace.shared.open(installerURL)
            status = .downloaded(installerURL)
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

        let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let updatesDirectory = downloadsDirectory.appendingPathComponent("417ssh-updates", isDirectory: true)
        try FileManager.default.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)

        let destinationURL = updatesDirectory.appendingPathComponent(asset.name)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
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

    var macInstallerAsset: Asset? {
        assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".dmg") && (name.contains("mac") || name.contains("darwin") || name.contains("417ssh"))
        } ?? assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }
}

private enum UpdateError: LocalizedError {
    case httpStatus(Int)
    case invalidAssetURL

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            return "GitHub 返回 HTTP \(status)"
        case .invalidAssetURL:
            return "安装包下载地址无效"
        }
    }
}
