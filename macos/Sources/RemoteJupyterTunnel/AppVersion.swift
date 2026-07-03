import Foundation

enum AppVersion {
    static let fallbackVersion = "0.4.3"
    static let repository = "Vonfre/417ssh"

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? fallbackVersion
    }

    static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    static var releasesURL: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }
}
