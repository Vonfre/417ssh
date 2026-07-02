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

    private var session: RemoteTerminalSession?
    private var isDisconnecting = false

    func connect(profile: SSHProfile) {
        disconnect()

        guard !profile.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .failed("目标主机为空")
            return
        }

        status = .connecting
        activeProfileID = profile.id
        terminalTitle = profile.targetAddress.isEmpty ? "SSH 终端" : profile.targetAddress

        do {
            let terminalView = RemotePTYTerminalView(frame: .zero)
            terminalView.configureAppearance()

            let delegate = RemotePTYTerminalDelegate(
                profileID: profile.id,
                onTitle: { [weak self] title in
                    Task { @MainActor in
                        guard let self, self.activeProfileID == profile.id else { return }
                        self.terminalTitle = title.isEmpty ? profile.targetAddress : title
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
            session = RemoteTerminalSession(
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
            status = .connected
        } catch {
            cleanupSession(removeView: true)
            status = .failed(error.localizedDescription)
            activeProfileID = nil
        }
    }

    func disconnect() {
        guard let session else {
            status = .disconnected
            activeProfileID = nil
            terminalTitle = "SSH 终端"
            return
        }

        isDisconnecting = true
        session.view.terminate()
        cleanupSession(removeView: true)
        isDisconnecting = false
        status = .disconnected
        activeProfileID = nil
        terminalTitle = "SSH 终端"
    }

    func clear() {
        session?.view.clearDisplay()
    }

    func sendControlC() {
        session?.view.sendBytes([3])
    }

    func view(for profileID: UUID) -> RemotePTYTerminalView? {
        guard session?.profileID == profileID else { return nil }
        return session?.view
    }

    private func handleTermination(profileID: UUID, exitCode: Int32?) {
        guard session?.profileID == profileID else { return }

        cleanupSession(removeView: true)
        activeProfileID = nil
        terminalTitle = "SSH 终端"

        if isDisconnecting {
            status = .disconnected
            return
        }

        let normalizedExitCode = exitCode.map(normalizedExitStatus)
        if normalizedExitCode == 0 {
            status = .disconnected
        } else {
            let codeText = normalizedExitCode.map(String.init) ?? "未知"
            status = .failed("终端已退出，状态码：\(codeText)")
        }
    }

    private func cleanupSession(removeView: Bool) {
        if removeView {
            session?.view.removeFromSuperview()
        }

        if let expectScriptURL = session?.expectScriptURL {
            try? FileManager.default.removeItem(at: expectScriptURL)
        }

        session = nil
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
    private let onTerminate: (Int32?) -> Void

    init(
        profileID: UUID,
        onTitle: @escaping (String) -> Void,
        onTerminate: @escaping (Int32?) -> Void
    ) {
        self.profileID = profileID
        self.onTitle = onTitle
        self.onTerminate = onTerminate
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onTerminate(exitCode)
    }
}
