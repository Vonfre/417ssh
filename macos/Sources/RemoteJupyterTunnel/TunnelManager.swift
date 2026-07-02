import Combine
import Darwin
import Foundation

@MainActor
final class TunnelManager: ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected:
                return "未连接"
            case .connecting:
                return "连接中"
            case .connected:
                return "已连接"
            case .failed:
                return "连接失败"
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
    @Published private(set) var logText: String = ""
    @Published private(set) var portConflict: Int?

    private var process: Process?
    private var outputPipe: Pipe?
    private var expectScriptURL: URL?
    private var activeLocalPort: Int?
    private var sshProcessID: pid_t?

    func connect(profile: SSHProfile, password: String) {
        disconnect()
        logText = ""
        appendLog("开始建立隧道：\(profile.name)")
        appendLog("本地地址：\(profile.localURLString)")
        portConflict = nil

        if isLocalPortInUse(profile.localPort) {
            let message = "本地端口 \(profile.localPort) 已被占用"
            status = .failed(message)
            activeProfileID = nil
            activeLocalPort = nil
            portConflict = profile.localPort
            appendLog(message)
            appendLog(localPortUsageMessage(port: profile.localPort))
            appendLog("如果占用进程是旧的 ssh 隧道，可以点击“关闭占用并重连”。")
            return
        }

        let hasPassword = !password.isEmpty
        let process = Process()
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            if hasPassword {
                let scriptURL = try writeExpectScript()
                expectScriptURL = scriptURL
                process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
                process.arguments = [scriptURL.path] + profile.sshArguments(includeBatchMode: false)
                process.environment = mergedEnvironment(password: password)
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = profile.sshArguments(includeBatchMode: true)
                process.environment = mergedEnvironment(password: nil)
            }

            appendLog(commandPreview(process: process, passwordWasProvided: hasPassword))

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.handleOutputChunk(chunk)
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                DispatchQueue.main.async {
                    self?.handleTermination(finishedProcess)
                }
            }

            self.process = process
            self.outputPipe = outputPipe
            activeProfileID = profile.id
            activeLocalPort = profile.localPort
            status = .connecting
            try process.run()
        } catch {
            cleanupProcess()
            status = .failed(error.localizedDescription)
            appendLog("隧道启动失败：\(error.localizedDescription)")
        }
    }

    func disconnect() {
        guard let process else {
            status = .disconnected
            activeProfileID = nil
            activeLocalPort = nil
            sshProcessID = nil
            portConflict = nil
            return
        }

        appendLog("正在断开隧道")
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        terminateSSHProcess(signal: SIGTERM)
        process.terminate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, process] in
            self?.terminateSSHProcess(signal: SIGKILL)
            guard process.isRunning else { return }
            process.interrupt()
        }

        cleanupProcess()
        status = .disconnected
        activeProfileID = nil
        portConflict = nil
    }

    func clearLog() {
        logText = ""
    }

    func closePortConflictAndReconnect(profile: SSHProfile) {
        let port = portConflict ?? profile.localPort
        appendLog("准备关闭占用本地端口 \(port) 的旧 ssh 隧道")

        let killedPIDs = terminateSSHListeners(on: port, signal: SIGTERM)
        if killedPIDs.isEmpty {
            appendLog("没有找到可自动关闭的 ssh 监听进程。")
            return
        }

        appendLog("已请求关闭旧 ssh 进程：\(killedPIDs.map(String.init).joined(separator: ", "))")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }

            if self.isLocalPortInUse(port) {
                let forcedPIDs = self.terminateSSHListeners(on: port, signal: SIGKILL)
                if !forcedPIDs.isEmpty {
                    self.appendLog("旧进程仍占用端口，已强制关闭：\(forcedPIDs.map(String.init).joined(separator: ", "))")
                }
            }

            self.connect(profile: profile, password: profile.sshPassword)
        }
    }

    private func handleOutputChunk(_ chunk: String) {
        let visibleChunk = extractSSHProcessID(from: chunk)
        if !visibleChunk.isEmpty {
            appendLog(visibleChunk)
        }
        promoteToConnectedIfReady()
    }

    private func extractSSHProcessID(from chunk: String) -> String {
        let marker = "REMOTE_JUPYTER_TUNNEL_SSH_PID="
        var visibleLines: [String] = []

        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineText = String(line)
            if lineText.contains(marker),
               let pidText = lineText.split(separator: "=").last,
               let pid = pid_t(String(pidText).trimmingCharacters(in: .whitespacesAndNewlines)) {
                sshProcessID = pid
            } else {
                visibleLines.append(lineText)
            }
        }

        return visibleLines.joined(separator: "\n")
    }

    private func promoteToConnectedIfReady() {
        guard status == .connecting else { return }
        if didStartExpectedLocalForward(in: logText.lowercased()) {
            status = .connected
        }
    }

    private func didStartExpectedLocalForward(in lowercasedChunk: String) -> Bool {
        guard let activeLocalPort else { return false }
        let portPattern = "port \(activeLocalPort)"

        return lowercasedChunk.contains("local forwarding listening")
            && lowercasedChunk.contains(portPattern)
    }

    private func isLocalPortInUse(_ port: Int) -> Bool {
        isLocalPortListening(port, host: "127.0.0.1")
            || isLocalPortListening(port, host: "::1")
    }

    private func isLocalPortListening(_ port: Int, host: String) -> Bool {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var result: UnsafeMutablePointer<addrinfo>?
        let lookupStatus = getaddrinfo(host, "\(port)", &hints, &result)
        guard lookupStatus == 0, let result else { return false }
        defer { freeaddrinfo(result) }

        var pointer: UnsafeMutablePointer<addrinfo>? = result
        while let current = pointer {
            let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if fd >= 0 {
                let connectStatus = Darwin.connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen)
                Darwin.close(fd)

                if connectStatus == 0 {
                    return true
                }
            }

            pointer = current.pointee.ai_next
        }

        return false
    }

    private func localPortUsageMessage(port: Int) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if output.isEmpty {
                return "没有拿到占用进程详情，可以在终端运行：lsof -nP -iTCP:\(port) -sTCP:LISTEN"
            }

            return "当前占用进程：\n\(output)"
        } catch {
            return "无法读取占用进程详情：\(error.localizedDescription)"
        }
    }

    private func terminateSSHListeners(on port: Int, signal: Int32) -> [pid_t] {
        listenerProcesses(on: port)
            .filter { $0.command == "ssh" }
            .map(\.pid)
            .uniqued()
            .filter { pid in
                Darwin.kill(pid, signal) == 0
            }
    }

    private func listenerProcesses(on port: Int) -> [ListenerProcess] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            return output
                .split(separator: "\n")
                .dropFirst()
                .compactMap { line in
                    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard fields.count >= 2, let pid = pid_t(String(fields[1])) else { return nil }
                    return ListenerProcess(command: String(fields[0]), pid: pid)
                }
        } catch {
            return []
        }
    }

    private func terminateSSHProcess(signal: Int32) {
        guard let sshProcessID, sshProcessID > 0 else { return }
        Darwin.kill(sshProcessID, signal)
    }

    private func handleTermination(_ finishedProcess: Process) {
        let exitCode = finishedProcess.terminationStatus
        terminateSSHProcess(signal: SIGTERM)
        cleanupProcess()

        if exitCode == 0 {
            status = .disconnected
            appendLog("隧道已停止")
        } else {
            let message = "SSH 已退出，状态码：\(exitCode)"
            status = .failed(message)
            appendLog(message)
        }

        activeProfileID = nil
    }

    private func cleanupProcess() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        process = nil
        activeLocalPort = nil
        sshProcessID = nil

        if let expectScriptURL {
            try? FileManager.default.removeItem(at: expectScriptURL)
            self.expectScriptURL = nil
        }
    }

    private func appendLog(_ text: String) {
        logText += text.hasSuffix("\n") ? text : text + "\n"
        if logText.count > 80_000 {
            logText = String(logText.suffix(60_000))
        }
    }

    private func writeExpectScript() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteJupyterTunnel", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("ssh-password-\(UUID().uuidString).expect")
        let script = """
        set timeout -1
        set password $env(REMOTE_JUPYTER_TUNNEL_PASSWORD)
        log_user 1

        spawn /usr/bin/ssh {*}$argv
        set ssh_pid [exp_pid]
        puts "REMOTE_JUPYTER_TUNNEL_SSH_PID=$ssh_pid"
        flush stdout

        trap {
            catch {exec /bin/kill -TERM $ssh_pid}
            exit 143
        } {SIGTERM SIGINT SIGHUP}

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
            eof {
                catch wait result
                exit [lindex $result 3]
            }
        }
        """

        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func mergedEnvironment(password: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"

        if let password {
            environment["REMOTE_JUPYTER_TUNNEL_PASSWORD"] = password
        }

        return environment
    }

    private func commandPreview(process: Process, passwordWasProvided: Bool) -> String {
        let executable = process.executableURL?.path ?? ""
        let arguments = process.arguments ?? []
        let command = ([executable] + arguments)
            .map(\.shellQuoted)
            .joined(separator: " ")

        if passwordWasProvided {
            return "命令：\(command)\n密码：已从应用配置读取，并通过进程环境传递给 ssh"
        }

        return "命令：\(command)\n密码：为空，将使用密钥或 ssh-agent"
    }
}

private extension String {
    var shellQuoted: String {
        guard !isEmpty else { return "''" }
        if range(of: #"[^A-Za-z0-9_@%+=:,./-]"#, options: .regularExpression) == nil {
            return self
        }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct ListenerProcess {
    let command: String
    let pid: pid_t
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
