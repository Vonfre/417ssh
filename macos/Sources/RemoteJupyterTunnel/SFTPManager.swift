import Combine
import Foundation

struct RemoteFileEntry: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let isLink: Bool
    let permissions: String
    let size: String
    let modified: String

    var kind: String {
        if isDirectory { return "文件夹" }
        if isLink { return "链接" }
        return "文件"
    }

    var displaySize: String {
        isDirectory ? "--" : size
    }
}

@MainActor
final class SFTPManager: ObservableObject {
    static let shared = SFTPManager()

    enum Status: Equatable {
        case idle
        case running
        case completed
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "文件空闲"
            case .running:
                return "文件处理中"
            case .completed:
                return "文件完成"
            case .failed:
                return "文件失败"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var logText = ""
    @Published private(set) var currentRemotePath = "."
    @Published private(set) var remoteEntries: [RemoteFileEntry] = []
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var transferProgressText = ""
    @Published private(set) var loadingRemotePath: String?

    var canNavigateDirectories: Bool {
        guard status == .running else { return true }
        if case .list = runningOperation {
            return true
        }
        return false
    }

    private var process: Process?
    private var outputPipe: Pipe?
    private var expectScriptURL: URL?
    private var runningOperation: Operation = .transfer(refreshProfile: nil, refreshPath: nil)
    private var directoryCache: [String: DirectorySnapshot] = [:]

    func upload(profile: SSHProfile, localPath: String, remotePath: String) {
        let recursiveFlag = isLocalDirectory(localPath) ? "-r " : ""
        let command = "put \(recursiveFlag)\(sftpQuote(localPath)) \(sftpQuote(remotePath))"
        runSFTP(command: command, profile: profile, title: "上传", operation: .transfer(refreshProfile: profile, refreshPath: remotePath))
    }

    func download(profile: SSHProfile, remotePath: String, localPath: String) {
        download(profile: profile, remotePath: remotePath, localPath: localPath, isDirectory: false)
    }

    func download(profile: SSHProfile, remotePath: String, localPath: String, isDirectory: Bool) {
        let recursiveFlag = isDirectory ? "-r " : ""
        let command = "get \(recursiveFlag)\(sftpQuote(remotePath)) \(sftpQuote(localPath))"
        runSFTP(command: command, profile: profile, title: "下载", operation: .transfer(refreshProfile: nil, refreshPath: nil))
    }

    func list(profile: SSHProfile, remotePath: String) {
        refreshDirectory(profile: profile, path: remotePath)
    }

    func refreshDirectory(profile: SSHProfile, path remotePath: String) {
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "." : remotePath
        runRemoteDirectoryListing(profile: profile, path: path)
    }

    func clear() {
        logText = ""
        if status != .running {
            status = .idle
        }
    }

    func cancel() {
        guard let process else {
            if status == .running {
                status = .idle
            }
            return
        }

        appendLog("正在停止 SFTP 操作")
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        process.terminate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [process] in
            guard process.isRunning else { return }
            process.interrupt()
        }

        cleanup()
        status = .idle
        loadingRemotePath = nil
    }

    private func runSFTP(command: String, profile: SSHProfile, title: String, operation: Operation) {
        guard status != .running else { return }
        guard !profile.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .failed("目标主机为空")
            appendLog("目标主机为空，请先在配置里填写目标主机。")
            return
        }

        logText = ""
        transferProgressText = ""
        loadingRemotePath = nil
        appendLog("\(title)：\(command)")
        status = .running
        runningOperation = operation
        activeProfileID = profile.id

        let process = Process()
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            let scriptURL = try writeSFTPExpectScript()
            expectScriptURL = scriptURL
            process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
            process.arguments = [scriptURL.path] + profile.sftpArguments()
            process.environment = mergedEnvironment(password: profile.sshPassword, command: command)

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.appendLog(chunk)
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                DispatchQueue.main.async {
                    self?.handleTermination(finishedProcess)
                }
            }

            self.process = process
            self.outputPipe = outputPipe
            try process.run()
        } catch {
            cleanup()
            status = .failed(error.localizedDescription)
            appendLog("SFTP 启动失败：\(error.localizedDescription)")
        }
    }

    private func runRemoteDirectoryListing(profile: SSHProfile, path: String) {
        if status == .running {
            if case .list = runningOperation {
                stopCurrentProcessForReplacement()
            } else {
                appendLog("当前正在传输文件，请等待传输结束后再切换目录。")
                return
            }
        }

        guard !profile.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .failed("目标主机为空")
            appendLog("目标主机为空，请先在配置里填写目标主机。")
            return
        }

        logText = ""
        transferProgressText = ""
        loadingRemotePath = path
        if let cached = directoryCache[cacheKey(profileID: profile.id, path: path)] {
            currentRemotePath = cached.path
            remoteEntries = cached.entries
        } else {
            remoteEntries = []
        }
        appendLog("刷新目录：\(path)")
        status = .running
        runningOperation = .list(path: path)
        activeProfileID = profile.id

        let process = Process()
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            let scriptURL = try writeSSHCommandExpectScript()
            expectScriptURL = scriptURL
            process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
            process.arguments = [scriptURL.path] + profile.remoteCommandArguments(
                command: remoteDirectoryListCommand(for: path),
                includeBatchMode: profile.sshPassword.isEmpty
            )
            process.environment = mergedEnvironment(password: profile.sshPassword, command: "")

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    self?.appendLog(chunk)
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                DispatchQueue.main.async {
                    self?.handleTermination(finishedProcess)
                }
            }

            self.process = process
            self.outputPipe = outputPipe
            try process.run()
        } catch {
            cleanup()
            status = .failed(error.localizedDescription)
            loadingRemotePath = nil
            appendLog("目录刷新失败：\(error.localizedDescription)")
        }
    }

    private func stopCurrentProcessForReplacement() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
        cleanup()
        status = .idle
        loadingRemotePath = nil
        runningOperation = .transfer(refreshProfile: nil, refreshPath: nil)
    }

    private func handleTermination(_ finishedProcess: Process) {
        let exitCode = finishedProcess.terminationStatus
        let finishedOperation = runningOperation
        cleanup()

        if exitCode == 0 {
            status = .completed
            if case .list(let path) = finishedOperation {
                let parsedListing = parseDirectoryListing(from: logText, requestedPath: path)
                currentRemotePath = parsedListing.path
                remoteEntries = parsedListing.entries
                let snapshot = DirectorySnapshot(path: parsedListing.path, entries: parsedListing.entries)
                directoryCache[cacheKey(profileID: activeProfileID, path: path)] = snapshot
                directoryCache[cacheKey(profileID: activeProfileID, path: parsedListing.path)] = snapshot
                loadingRemotePath = nil
                if let warning = parsedListing.warning {
                    appendLog("目录刷新提示：\(warning)")
                }
            } else {
                transferProgressText = "传输完成"
            }
            appendLog("SFTP 操作完成")

            if case .transfer(let refreshProfile, let refreshPath) = finishedOperation,
               let refreshProfile,
               let refreshPath {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.refreshDirectory(profile: refreshProfile, path: refreshPath)
                }
            }
        } else {
            let message = extractRemoteError(from: logText) ?? "SFTP 已退出，状态码：\(exitCode)"
            status = .failed(message)
            loadingRemotePath = nil
            appendLog(message)
        }
        runningOperation = .transfer(refreshProfile: nil, refreshPath: nil)
    }

    private func cleanup() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        process = nil

        if let expectScriptURL {
            try? FileManager.default.removeItem(at: expectScriptURL)
            self.expectScriptURL = nil
        }
    }

    private func appendLog(_ text: String) {
        if case .transfer = runningOperation {
            updateTransferProgress(from: text)
        }

        if case .list = runningOperation {
            logText += text
        } else {
            logText += text.hasSuffix("\n") ? text : text + "\n"
        }

        if logText.count > 80_000 {
            logText = String(logText.suffix(60_000))
        }
    }

    private func updateTransferProgress(from text: String) {
        let normalized = text.replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineText = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard lineText.contains("%") else { continue }
            transferProgressText = compactTransferProgress(lineText)
        }
    }

    private func compactTransferProgress(_ line: String) -> String {
        line
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeSFTPExpectScript() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteJupyterTunnel", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("sftp-\(UUID().uuidString).expect")
        let script = """
        set timeout -1
        set password $env(REMOTE_JUPYTER_TUNNEL_PASSWORD)
        set command $env(REMOTE_JUPYTER_SFTP_COMMAND)
        log_user 0

        spawn /usr/bin/sftp {*}$argv
        set sftp_pid [exp_pid]

        trap {
            catch {exec /bin/kill -TERM $sftp_pid}
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
            -re "sftp> $" {
            }
            eof {
                catch wait result
                exit [lindex $result 3]
            }
        }

        log_user 1
        set commands [split $command "\\n"]
        foreach cmd $commands {
            if {$cmd eq ""} {
                continue
            }
            send -- "$cmd\\r"
            expect {
                -re "sftp> $" {
                }
                eof {
                    catch wait result
                    exit [lindex $result 3]
                }
            }
        }

        send "bye\\r"
        expect {
            -re "sftp> $" {
                send "bye\\r"
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

    private func writeSSHCommandExpectScript() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteJupyterTunnel", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("ssh-command-\(UUID().uuidString).expect")
        let script = """
        set timeout -1
        set password $env(REMOTE_JUPYTER_TUNNEL_PASSWORD)

        spawn /usr/bin/ssh {*}$argv
        set ssh_pid [exp_pid]

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

    private func mergedEnvironment(password: String, command: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["REMOTE_JUPYTER_TUNNEL_PASSWORD"] = password
        environment["REMOTE_JUPYTER_SFTP_COMMAND"] = command
        return environment
    }

    private func sftpQuote(_ value: String) -> String {
        let escaped = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func isLocalDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }

    private func remoteDirectoryListCommand(for path: String) -> String {
        let launcher = """
        input_path=\(shellQuote(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "." : path))
        case "$input_path" in
          "~") input_path="${HOME:-.}" ;;
          "~/"*) input_path="${HOME:-.}/${input_path#~/}" ;;
        esac
        if [ ! -d "$input_path" ]; then
          printf 'ERROR\\t不是文件夹或没有权限：%s\\0' "$input_path"
          exit 2
        fi
        cwd=$(cd "$input_path" 2>/dev/null && pwd -P)
        if [ -z "$cwd" ]; then
          printf 'ERROR\\t无法进入目录：%s\\0' "$input_path"
          exit 2
        fi
        if ! command -v find >/dev/null 2>&1; then
          printf 'ERROR\\t远程服务器没有 find 命令，无法读取目录。\\0'
          exit 127
        fi
        printf 'CWD\\t%s\\0' "$cwd"
        if ! find "$cwd" -mindepth 1 -maxdepth 1 -printf 'ENTRY\\t%f\\t%p\\t%y\\t%M\\t%s\\t%TY-%Tm-%Td %TH:%TM\\0' 2>/dev/null; then
          printf 'ERROR\\t远程 find 不支持 -printf，无法读取目录。\\0'
          exit 2
        fi
        """
        return "sh -lc \(shellQuote(launcher))"
    }

    private func parseDirectoryListing(from text: String, requestedPath: String) -> DirectoryParseResult {
        var actualPath = requestedPath
        var entries: [RemoteFileEntry] = []
        var warning: String?

        for record in text.components(separatedBy: "\u{0}") {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("CWD\t") {
                actualPath = String(trimmed.dropFirst(4))
                continue
            }

            if trimmed.hasPrefix("ERROR\t") {
                let error = String(trimmed.dropFirst(6))
                warning = warning.map { $0 + "\n" + error } ?? error
                continue
            }

            guard trimmed.hasPrefix("ENTRY\t") else {
                continue
            }

            let fields = trimmed.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7 else { continue }
            let kind = fields[3]
            let size = Int64(fields[5]) ?? 0

            entries.append(
                RemoteFileEntry(
                    name: fields[1],
                    path: fields[2],
                    isDirectory: kind == "d",
                    isLink: kind == "l",
                    permissions: fields[4],
                    size: formattedByteCount(size),
                    modified: fields[6]
                )
            )
        }

        let sortedEntries = entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return DirectoryParseResult(
            path: actualPath,
            entries: parentEntry(for: actualPath).map { [$0] + sortedEntries } ?? sortedEntries,
            warning: warning
        )
    }

    private func extractRemoteError(from text: String) -> String? {
        for record in text.components(separatedBy: "\u{0}").reversed() {
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("ERROR\t") {
                return String(trimmed.dropFirst(6))
            }
        }

        return nil
    }

    private func parentEntry(for path: String) -> RemoteFileEntry? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "/" else { return nil }
        return RemoteFileEntry(
            name: "..",
            path: parentRemotePath(trimmed),
            isDirectory: true,
            isLink: false,
            permissions: "上级目录",
            size: "",
            modified: ""
        )
    }

    private func formattedByteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func joinedRemotePath(_ basePath: String, _ name: String) -> String {
        if name == ".." {
            return parentRemotePath(basePath)
        }

        if basePath == "." || basePath == "./" {
            return name
        }

        if basePath == "/" {
            return "/" + name
        }

        return basePath.hasSuffix("/") ? basePath + name : basePath + "/" + name
    }

    private func parentRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "/" else { return "." }
        let parts = trimmed.split(separator: "/").dropLast()
        guard !parts.isEmpty else { return trimmed.hasPrefix("/") ? "/" : "." }
        let parent = parts.joined(separator: "/")
        return trimmed.hasPrefix("/") ? "/" + parent : parent
    }

    private func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.range(of: #"[^A-Za-z0-9_@%+=:,./-]"#, options: .regularExpression) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct DirectoryParseResult {
        let path: String
        let entries: [RemoteFileEntry]
        let warning: String?
    }

    private struct DirectorySnapshot {
        let path: String
        let entries: [RemoteFileEntry]
    }

    private func cacheKey(profileID: UUID?, path: String) -> String {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(profileID?.uuidString ?? "unknown")::\(normalizedPath.isEmpty ? "." : normalizedPath)"
    }

    private enum Operation {
        case transfer(refreshProfile: SSHProfile?, refreshPath: String?)
        case list(path: String)
    }
}
