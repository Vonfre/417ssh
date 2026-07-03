import Foundation

enum AppLaunchSanitizer {
    static func clearOwnQuarantineIfPossible() {
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        guard appURL.pathExtension == "app" else { return }
        clearQuarantine(at: appURL)
    }

    private static func clearQuarantine(at url: URL) {
        guard FileManager.default.fileExists(atPath: "/usr/bin/xattr") else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        if let nullHandle = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = nullHandle
            process.standardError = nullHandle
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }
}
