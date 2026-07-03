import AppKit
import Combine
import Foundation
import SwiftTerm

@MainActor
final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected:
                return "终端未连接"
            case .connecting:
                return "终端连接中"
            case .connected:
                return "终端已连接"
            case .failed:
                return "终端连接失败"
            }
        }

        var isRunning: Bool {
            switch self {
            case .connecting, .connected:
                return true
            case .disconnected, .failed:
                return false
            }
        }
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var terminalTitle = "SSH 终端"
    @Published private(set) var statusByProfileID: [UUID: Status] = [:]
    @Published private(set) var terminalTitleByProfileID: [UUID: String] = [:]
    @Published private(set) var currentDirectoryByProfileID: [UUID: String] = [:]

    private var sessions: [UUID: RemoteTerminalSession] = [:]
    private var disconnectingProfileIDs: Set<UUID> = []
    private var inputBufferByProfileID: [UUID: [UInt8]] = [:]

    func connect(profile: SSHProfile) {
        if status(for: profile.id).isRunning, sessions[profile.id] != nil {
            activeProfileID = profile.id
            status = status(for: profile.id)
            terminalTitle = title(for: profile.id)
            return
        }

        disconnect(profileID: profile.id, updateLegacySelection: false)

        guard !profile.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setStatus(.failed("目标主机为空"), for: profile.id)
            return
        }

        activeProfileID = profile.id
        setTitle(profile.targetAddress.isEmpty ? "SSH 终端" : profile.targetAddress, for: profile.id)
        setStatus(.connecting, for: profile.id)

        do {
            let terminalView = RemotePTYTerminalView(frame: .zero)
            terminalView.configureAppearance()
            terminalView.onInput = { [weak self] input in
                Task { @MainActor in
                    self?.recordInput(input, for: profile.id)
                }
            }

            let delegate = RemotePTYTerminalDelegate(
                profileID: profile.id,
                onTitle: { [weak self] title in
                    Task { @MainActor in
                        guard let self, self.sessions[profile.id] != nil else { return }
                        self.setTitle(title.isEmpty ? profile.targetAddress : title, for: profile.id)
                    }
                },
                onDirectory: { [weak self] directory in
                    Task { @MainActor in
                        guard let self, self.sessions[profile.id] != nil else { return }
                        if let normalized = Self.normalizedTerminalDirectory(directory) {
                            self.currentDirectoryByProfileID[profile.id] = normalized
                        } else {
                            self.currentDirectoryByProfileID.removeValue(forKey: profile.id)
                        }
                    }
                },
                onTerminate: { [weak self] exitCode in
                    Task { @MainActor in
                        self?.handleTermination(profileID: profile.id, exitCode: exitCode)
                    }
                }
            )
            terminalView.processDelegate = delegate

            let launch = try launchConfiguration(for: profile)
            sessions[profile.id] = RemoteTerminalSession(
                profileID: profile.id,
                view: terminalView,
                delegate: delegate,
                expectScriptURL: launch.expectScriptURL
            )

            terminalView.startProcess(
                executable: launch.executable,
                args: launch.arguments,
                environment: launch.environment,
                execName: launch.execName
            )
            terminalView.window?.makeFirstResponder(terminalView)
            setStatus(.connected, for: profile.id)
        } catch {
            cleanupSession(profileID: profile.id, removeView: true)
            setStatus(.failed(error.localizedDescription), for: profile.id)
            refreshLegacySelectionAfterProfileRemoval(profile.id)
        }
    }

    func disconnect() {
        for profileID in Array(sessions.keys) {
            disconnect(profileID: profileID, updateLegacySelection: false)
        }

        statusByProfileID.removeAll()
        terminalTitleByProfileID.removeAll()
        currentDirectoryByProfileID.removeAll()
        inputBufferByProfileID.removeAll()
        activeProfileID = nil
        status = .disconnected
        terminalTitle = "SSH 终端"
    }

    func disconnect(profileID: UUID, updateLegacySelection: Bool = true) {
        guard let session = sessions[profileID] else {
            setStatus(.disconnected, for: profileID)
            if updateLegacySelection {
                refreshLegacySelectionAfterProfileRemoval(profileID)
            }
            return
        }

        disconnectingProfileIDs.insert(profileID)
        session.view.terminate()
        cleanupSession(profileID: profileID, removeView: true)
        disconnectingProfileIDs.remove(profileID)
        currentDirectoryByProfileID.removeValue(forKey: profileID)
        inputBufferByProfileID.removeValue(forKey: profileID)
        setStatus(.disconnected, for: profileID)
        if updateLegacySelection {
            refreshLegacySelectionAfterProfileRemoval(profileID)
        }
    }

    func clear() {
        guard let activeProfileID else { return }
        clear(profileID: activeProfileID)
    }

    func clear(profileID: UUID) {
        sessions[profileID]?.view.clearDisplay()
    }

    func sendControlC() {
        guard let activeProfileID else { return }
        sendControlC(profileID: activeProfileID)
    }

    func sendControlC(profileID: UUID) {
        sessions[profileID]?.view.sendBytes([3])
    }

    func sendText(_ text: String, profileID: UUID) {
        sessions[profileID]?.view.sendBytes(Array(text.utf8))
    }

    func requestCurrentDirectory(profileID: UUID) {
        // Current directory is tracked from OSC 7 shell reports and typed `cd` commands.
        // Avoid injecting a visible `printf ...` probe into the user's interactive shell.
    }

    func view(for profileID: UUID) -> RemotePTYTerminalView? {
        sessions[profileID]?.view
    }

    func status(for profileID: UUID) -> Status {
        statusByProfileID[profileID] ?? .disconnected
    }

    func isRunning(_ profileID: UUID) -> Bool {
        status(for: profileID).isRunning
    }

    func title(for profileID: UUID) -> String {
        terminalTitleByProfileID[profileID] ?? "SSH 终端"
    }

    func currentDirectory(for profileID: UUID) -> String? {
        currentDirectoryByProfileID[profileID]
    }

    private func handleTermination(profileID: UUID, exitCode: Int32?) {
        guard sessions[profileID] != nil else { return }

        cleanupSession(profileID: profileID, removeView: true)
        currentDirectoryByProfileID.removeValue(forKey: profileID)
        inputBufferByProfileID.removeValue(forKey: profileID)

        if disconnectingProfileIDs.contains(profileID) {
            setStatus(.disconnected, for: profileID)
            refreshLegacySelectionAfterProfileRemoval(profileID)
            return
        }

        let normalizedExitCode = exitCode.map(normalizedExitStatus)
        if normalizedExitCode == 0 {
            setStatus(.disconnected, for: profileID)
        } else {
            let codeText = normalizedExitCode.map(String.init) ?? "未知"
            setStatus(.failed("终端已退出，状态码：\(codeText)"), for: profileID)
        }
        refreshLegacySelectionAfterProfileRemoval(profileID)
    }

    private func cleanupSession(profileID: UUID, removeView: Bool) {
        let session = sessions[profileID]
        if removeView {
            session?.view.removeFromSuperview()
        }

        if let expectScriptURL = session?.expectScriptURL {
            try? FileManager.default.removeItem(at: expectScriptURL)
        }

        sessions.removeValue(forKey: profileID)
    }

    private func setStatus(_ nextStatus: Status, for profileID: UUID) {
        statusByProfileID[profileID] = nextStatus
        if activeProfileID == profileID {
            status = nextStatus
        }
    }

    private func setTitle(_ title: String, for profileID: UUID) {
        terminalTitleByProfileID[profileID] = title
        if activeProfileID == profileID {
            terminalTitle = title
        }
    }

    private func refreshLegacySelectionAfterProfileRemoval(_ removedProfileID: UUID) {
        if activeProfileID == removedProfileID {
            activeProfileID = sessions.keys.first
        }

        if let activeProfileID {
            status = status(for: activeProfileID)
            terminalTitle = title(for: activeProfileID)
        } else {
            status = .disconnected
            terminalTitle = "SSH 终端"
        }
    }

    private static func normalizedTerminalDirectory(_ directory: String?) -> String? {
        guard let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if let url = URL(string: directory), url.scheme == "file" {
            let path = url.path.removingPercentEncoding ?? url.path
            return path.isEmpty ? nil : path
        }

        return directory
    }

    private func recordInput(_ input: ArraySlice<UInt8>, for profileID: UUID) {
        var buffer = inputBufferByProfileID[profileID] ?? []

        for byte in input {
            switch byte {
            case 3, 21:
                buffer.removeAll()
            case 8, 127:
                if !buffer.isEmpty {
                    buffer.removeLast()
                }
            case 10, 13:
                if let command = String(bytes: buffer, encoding: .utf8),
                   let directory = directoryAfterChangingDirectory(command: command, profileID: profileID) {
                    currentDirectoryByProfileID[profileID] = directory
                }
                buffer.removeAll()
            case 0..<32:
                continue
            default:
                buffer.append(byte)
            }
        }

        inputBufferByProfileID[profileID] = buffer
    }

    private func directoryAfterChangingDirectory(command: String, profileID: UUID) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let words = Self.shellWords(trimmed)
        guard words.first == "cd" else { return nil }

        let target = words.dropFirst().first ?? "~"
        guard target != "-" else { return nil }
        return Self.resolvedRemoteDirectory(target, base: currentDirectoryByProfileID[profileID])
    }

    private static func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        for character in command {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                continue
            }

            if character == " " || character == "\t" {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    private static func resolvedRemoteDirectory(_ path: String, base: String?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "~" }
        if trimmed == "~" || trimmed.hasPrefix("~/") || trimmed.hasPrefix("/") {
            return normalizedPOSIXPath(trimmed)
        }

        guard let base, !base.isEmpty else {
            return trimmed
        }

        if base == "~" {
            return normalizedPOSIXPath("~/\(trimmed)")
        }
        return normalizedPOSIXPath("\(base)/\(trimmed)")
    }

    private static func normalizedPOSIXPath(_ path: String) -> String {
        let hasRoot = path.hasPrefix("/")
        let hasHome = path == "~" || path.hasPrefix("~/")
        let prefix = hasRoot ? "/" : (hasHome ? "~" : "")
        let trimmed = hasRoot ? String(path.dropFirst()) : (hasHome ? String(path.dropFirst(2)) : path)
        var components: [String] = []

        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(String(component))
            }
        }

        if prefix == "/" {
            return "/" + components.joined(separator: "/")
        }
        if prefix == "~" {
            return components.isEmpty ? "~" : "~/" + components.joined(separator: "/")
        }
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    private func launchConfiguration(for profile: SSHProfile) throws -> RemoteTerminalLaunchConfiguration {
        if profile.sshPassword.isEmpty {
            return RemoteTerminalLaunchConfiguration(
                executable: "/usr/bin/ssh",
                arguments: profile.terminalArguments(includeBatchMode: false),
                environment: terminalEnvironment(password: ""),
                execName: "ssh",
                expectScriptURL: nil
            )
        }

        let scriptURL = try writeExpectScript()
        return RemoteTerminalLaunchConfiguration(
            executable: "/usr/bin/expect",
            arguments: [scriptURL.path] + profile.terminalArguments(includeBatchMode: false),
            environment: terminalEnvironment(password: profile.sshPassword),
            execName: "ssh",
            expectScriptURL: scriptURL
        )
    }

    private func terminalEnvironment(password: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "zh_CN.UTF-8"
        environment["LC_CTYPE"] = environment["LC_CTYPE"] ?? "UTF-8"
        environment["REMOTE_JUPYTER_TUNNEL_PASSWORD"] = password
        return environment.map { "\($0.key)=\($0.value)" }
    }

    private func writeExpectScript() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteJupyterTunnel", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("ssh-pty-\(UUID().uuidString).expect")
        let script = """
        set timeout 8
        set password $env(REMOTE_JUPYTER_TUNNEL_PASSWORD)
        log_user 0

        spawn /usr/bin/ssh {*}$argv
        set ssh_pid [exp_pid]

        proc sync_window_size {} {
            global spawn_out
            if {![info exists spawn_out(slave,name)]} {
                return
            }
            catch {
                set size [exec stty size]
                scan $size "%d %d" rows columns
                exec stty rows $rows columns $columns < $spawn_out(slave,name)
            }
        }
        sync_window_size

        trap {
            catch {exec /bin/kill -TERM $ssh_pid}
            exit 143
        } {SIGTERM SIGINT SIGHUP}
        trap {
            sync_window_size
        } {WINCH}

        expect {
            -re "(?i)are you sure you want to continue connecting.*" {
                send "yes\\r"
                exp_continue
            }
            -re "(?i)password:" {
                send -- "$password\\r"
                exp_continue
            }
            -re "(?i)passphrase for key.*:" {
                send -- "$password\\r"
                exp_continue
            }
            timeout {
            }
            eof {
                catch wait result
                exit [lindex $result 3]
            }
        }

        log_user 1
        send "\\r"
        set timeout -1
        interact
        catch wait result
        exit [lindex $result 3]
        """

        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func normalizedExitStatus(_ status: Int32) -> Int32 {
        if status > 255 {
            return (status >> 8) & 0xff
        }
        return status
    }
}

private struct RemoteTerminalSession {
    let profileID: UUID
    let view: RemotePTYTerminalView
    let delegate: RemotePTYTerminalDelegate
    let expectScriptURL: URL?
}

private struct RemoteTerminalLaunchConfiguration {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let execName: String?
    let expectScriptURL: URL?
}

final class RemotePTYTerminalView: LocalProcessTerminalView {
    var onInput: ((ArraySlice<UInt8>) -> Void)?

    func configureAppearance() {
        wantsLayer = true
        autoresizingMask = [.width, .height]

        let foreground = NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.92, alpha: 1)
        let background = NSColor(calibratedRed: 0.055, green: 0.065, blue: 0.075, alpha: 1)

        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        nativeForegroundColor = foreground
        nativeBackgroundColor = background
        layer?.backgroundColor = background.cgColor
        caretColor = .systemGreen
        caretTextColor = .black
        optionAsMetaKey = true
        allowMouseReporting = true
        getTerminal().setCursorStyle(.steadyBlock)

        do {
            try setUseMetal(false)
        } catch {
            // CPU rendering is reliable during live resize and avoids bundling Metal shader resources.
        }
    }

    func sendBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        send(source: self, data: bytes[...])
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(data)
        super.send(source: source, data: data)
    }

    func clearDisplay() {
        feed(text: "\u{001B}[2J\u{001B}[3J\u{001B}[H")
    }

    override func rightMouseDown(with event: NSEvent) {
        guard
            let pasted = NSPasteboard.general.string(forType: .string),
            !pasted.isEmpty
        else {
            super.rightMouseDown(with: event)
            return
        }

        sendBytes(Array(pasted.replacingOccurrences(of: "\n", with: "\r").utf8))
    }
}

private final class RemotePTYTerminalDelegate: LocalProcessTerminalViewDelegate {
    let profileID: UUID
    private let onTitle: (String) -> Void
    private let onDirectory: (String?) -> Void
    private let onTerminate: (Int32?) -> Void

    init(
        profileID: UUID,
        onTitle: @escaping (String) -> Void,
        onDirectory: @escaping (String?) -> Void,
        onTerminate: @escaping (Int32?) -> Void
    ) {
        self.profileID = profileID
        self.onTitle = onTitle
        self.onDirectory = onDirectory
        self.onTerminate = onTerminate
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onDirectory(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onTerminate(exitCode)
    }
}
