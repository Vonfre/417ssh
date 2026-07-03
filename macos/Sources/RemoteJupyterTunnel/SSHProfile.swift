import Foundation

enum WorkspaceKind: String, Codable, CaseIterable, Identifiable {
    case jupyter
    case rstudio
    case terminal
    case sftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jupyter:
            return "Jupyter"
        case .rstudio:
            return "RStudio"
        case .terminal:
            return "终端"
        case .sftp:
            return "SFTP"
        }
    }

    var sidebarTitle: String {
        switch self {
        case .jupyter:
            return "Jupyter 工作区"
        case .rstudio:
            return "RStudio 工作区"
        case .terminal:
            return "终端工作区"
        case .sftp:
            return "SFTP 工作区"
        }
    }

    var systemImage: String {
        switch self {
        case .jupyter:
            return "rectangle.connected.to.line.below"
        case .rstudio:
            return "display"
        case .terminal:
            return "terminal"
        case .sftp:
            return "folder.badge.gearshape"
        }
    }

    var isWebWorkspace: Bool {
        switch self {
        case .jupyter, .rstudio:
            return true
        case .terminal, .sftp:
            return false
        }
    }

    var emptyText: String {
        switch self {
        case .jupyter:
            return "还没有 Jupyter 配置"
        case .rstudio:
            return "还没有 RStudio 配置"
        case .terminal:
            return "还没有终端配置"
        case .sftp:
            return "还没有 SFTP 配置"
        }
    }
}

struct SSHProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var workspaceKind: WorkspaceKind
    var name: String
    var localPort: Int
    var remoteHost: String
    var remotePort: Int
    var jumpUser: String
    var jumpHost: String
    var jumpPort: Int
    var targetUser: String
    var targetHost: String
    var targetPort: Int
    var jupyterPath: String
    var sshPassword: String
    var identityFile: String
    var compressionEnabled: Bool
    var verboseLogging: Bool
    var allowRemoteLocalPortAccess: Bool
    var keepAliveEnabled: Bool
    var keepAliveInterval: Int
    var keepAliveCountMax: Int
    var useSSHConfig: Bool

    init(
        id: UUID = UUID(),
        workspaceKind: WorkspaceKind = .jupyter,
        name: String = "新 Jupyter",
        localPort: Int = 8000,
        remoteHost: String = "127.0.0.1",
        remotePort: Int = 8888,
        jumpUser: String = "",
        jumpHost: String = "",
        jumpPort: Int = 22,
        targetUser: String = "",
        targetHost: String = "",
        targetPort: Int = 22,
        jupyterPath: String = "/lab/tree/work",
        sshPassword: String = "",
        identityFile: String = "",
        compressionEnabled: Bool = true,
        verboseLogging: Bool = false,
        allowRemoteLocalPortAccess: Bool = false,
        keepAliveEnabled: Bool = true,
        keepAliveInterval: Int = 30,
        keepAliveCountMax: Int = 120,
        useSSHConfig: Bool = false
    ) {
        self.id = id
        self.workspaceKind = workspaceKind
        self.name = name
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.jumpUser = jumpUser
        self.jumpHost = jumpHost
        self.jumpPort = jumpPort
        self.targetUser = targetUser
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.jupyterPath = jupyterPath
        self.sshPassword = sshPassword
        self.identityFile = identityFile
        self.compressionEnabled = compressionEnabled
        self.verboseLogging = verboseLogging
        self.allowRemoteLocalPortAccess = allowRemoteLocalPortAccess
        self.keepAliveEnabled = keepAliveEnabled
        self.keepAliveInterval = keepAliveInterval
        self.keepAliveCountMax = keepAliveCountMax
        self.useSSHConfig = useSSHConfig
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceKind
        case name
        case localPort
        case remoteHost
        case remotePort
        case jumpUser
        case jumpHost
        case jumpPort
        case targetUser
        case targetHost
        case targetPort
        case jupyterPath
        case sshPassword
        case identityFile
        case compressionEnabled
        case verboseLogging
        case allowRemoteLocalPortAccess
        case keepAliveEnabled
        case keepAliveInterval
        case keepAliveCountMax
        case useSSHConfig
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        workspaceKind = try container.decodeIfPresent(WorkspaceKind.self, forKey: .workspaceKind) ?? .jupyter
        name = try container.decode(String.self, forKey: .name)
        localPort = try container.decode(Int.self, forKey: .localPort)
        remoteHost = try container.decode(String.self, forKey: .remoteHost)
        remotePort = try container.decode(Int.self, forKey: .remotePort)
        jumpUser = try container.decode(String.self, forKey: .jumpUser)
        jumpHost = try container.decode(String.self, forKey: .jumpHost)
        jumpPort = try container.decode(Int.self, forKey: .jumpPort)
        targetUser = try container.decode(String.self, forKey: .targetUser)
        targetHost = try container.decode(String.self, forKey: .targetHost)
        targetPort = try container.decode(Int.self, forKey: .targetPort)
        jupyterPath = try container.decode(String.self, forKey: .jupyterPath)
        sshPassword = try container.decodeIfPresent(String.self, forKey: .sshPassword) ?? ""
        identityFile = try container.decode(String.self, forKey: .identityFile)
        compressionEnabled = try container.decode(Bool.self, forKey: .compressionEnabled)
        verboseLogging = try container.decode(Bool.self, forKey: .verboseLogging)
        allowRemoteLocalPortAccess = try container.decode(Bool.self, forKey: .allowRemoteLocalPortAccess)
        keepAliveEnabled = try container.decodeIfPresent(Bool.self, forKey: .keepAliveEnabled) ?? true
        keepAliveInterval = try container.decodeIfPresent(Int.self, forKey: .keepAliveInterval) ?? 30
        keepAliveCountMax = try container.decodeIfPresent(Int.self, forKey: .keepAliveCountMax) ?? 120
        useSSHConfig = try container.decodeIfPresent(Bool.self, forKey: .useSSHConfig) ?? false
    }

    var localURL: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = localPort
        components.path = jupyterPath.normalizedHTTPPath
        return components.url
    }

    var localURLString: String {
        localURL?.absoluteString ?? "http://127.0.0.1:\(localPort)\(jupyterPath.normalizedHTTPPath)"
    }

    var targetAddress: String {
        let trimmedUser = targetUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else { return trimmedHost }
        return "\(trimmedUser)@\(trimmedHost)"
    }

    var jumpAddress: String {
        let trimmedUser = jumpUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = jumpHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostPart = trimmedUser.isEmpty ? trimmedHost : "\(trimmedUser)@\(trimmedHost)"
        return "\(hostPart):\(jumpPort)"
    }

    var hasJumpHost: Bool {
        !jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var forwardSpec: String {
        "\(localPort):\(remoteHost):\(remotePort)"
    }

    var previewCommand: String {
        switch workspaceKind {
        case .jupyter, .rstudio:
            return sshArguments(includeBatchMode: false).map { argument in
                argument.shellQuoted
            }.joined(separator: " ")
        case .terminal, .sftp:
            return terminalArguments(includeBatchMode: false).map { argument in
                argument.shellQuoted
            }.joined(separator: " ")
        }
    }

    var jupyterPreviewCommand: String {
        sshArguments(includeBatchMode: false).map { argument in
            argument.shellQuoted
        }.joined(separator: " ")
    }

    func sshArguments(includeBatchMode: Bool) -> [String] {
        var args: [String] = []

        if compressionEnabled {
            args.append("-C")
        }

        args.append(contentsOf: sshConfigArguments())
        args.append("-N")

        if allowRemoteLocalPortAccess {
            args.append("-g")
        }

        if verboseLogging {
            args.append("-v")
        }

        if includeBatchMode {
            args.append(contentsOf: ["-o", "BatchMode=yes"])
        }

        args.append(contentsOf: keepAliveArguments())
        args.append(contentsOf: ["-o", "ExitOnForwardFailure=yes"])

        if !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["-i", identityFile.expandingTildeInPath])
        }

        if targetPort != 22 {
            args.append(contentsOf: ["-p", "\(targetPort)"])
        }

        args.append(contentsOf: [
            "-L", forwardSpec
        ])

        if hasJumpHost {
            args.append(contentsOf: ["-J", jumpAddress])
        }

        args.append(targetAddress)

        return args
    }

    func terminalArguments(includeBatchMode: Bool) -> [String] {
        var args: [String] = []

        if compressionEnabled {
            args.append("-C")
        }

        args.append(contentsOf: sshConfigArguments())
        args.append("-tt")

        if includeBatchMode {
            args.append(contentsOf: ["-o", "BatchMode=yes"])
        }

        args.append(contentsOf: keepAliveArguments())

        if !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["-i", identityFile.expandingTildeInPath])
        }

        if targetPort != 22 {
            args.append(contentsOf: ["-p", "\(targetPort)"])
        }

        if hasJumpHost {
            args.append(contentsOf: ["-J", jumpAddress])
        }

        args.append(targetAddress)
        return args
    }

    func sftpArguments() -> [String] {
        var args: [String] = []

        args.append(contentsOf: sshConfigArguments())
        args.append(contentsOf: keepAliveArguments())

        if !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["-i", identityFile.expandingTildeInPath])
        }

        if targetPort != 22 {
            args.append(contentsOf: ["-P", "\(targetPort)"])
        }

        if hasJumpHost {
            args.append(contentsOf: ["-J", jumpAddress])
        }

        args.append(targetAddress)
        return args
    }

    func remoteCommandArguments(command: String, includeBatchMode: Bool) -> [String] {
        var args: [String] = []

        if compressionEnabled {
            args.append("-C")
        }

        args.append(contentsOf: sshConfigArguments())
        args.append(contentsOf: ["-T", "-o", "LogLevel=ERROR"])

        if includeBatchMode {
            args.append(contentsOf: ["-o", "BatchMode=yes"])
        }

        args.append(contentsOf: keepAliveArguments())

        if !identityFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(contentsOf: ["-i", identityFile.expandingTildeInPath])
        }

        if targetPort != 22 {
            args.append(contentsOf: ["-p", "\(targetPort)"])
        }

        if hasJumpHost {
            args.append(contentsOf: ["-J", jumpAddress])
        }

        args.append(targetAddress)
        args.append(command)
        return args
    }

    private func keepAliveArguments() -> [String] {
        guard keepAliveEnabled else { return [] }

        let interval = min(max(keepAliveInterval, 10), 600)
        let countMax = min(max(keepAliveCountMax, 3), 720)

        return [
            "-o", "ServerAliveInterval=\(interval)",
            "-o", "ServerAliveCountMax=\(countMax)",
            "-o", "TCPKeepAlive=yes"
        ]
    }

    private func sshConfigArguments() -> [String] {
        useSSHConfig ? [] : ["-F", "none"]
    }
}

extension SSHProfile {
    static let sample = SSHProfile()

    static func blank(number: Int, kind: WorkspaceKind) -> SSHProfile {
        SSHProfile(
            workspaceKind: kind,
            name: kind.defaultProfileName(number: number),
            localPort: kind.defaultLocalPort(number: number),
            remoteHost: kind.defaultRemoteHost,
            remotePort: kind.defaultRemotePort,
            jumpUser: "",
            jumpHost: "",
            jumpPort: 22,
            targetUser: "",
            targetHost: "",
            targetPort: 22,
            jupyterPath: kind.defaultHTTPPath,
            compressionEnabled: true,
            verboseLogging: false,
            allowRemoteLocalPortAccess: false,
            keepAliveEnabled: true,
            keepAliveInterval: 30,
            keepAliveCountMax: 120,
            useSSHConfig: false
        )
    }
}

private extension WorkspaceKind {
    func defaultProfileName(number: Int) -> String {
        switch self {
        case .jupyter:
            return number <= 1 ? "新 Jupyter" : "新 Jupyter \(number)"
        case .rstudio:
            return number <= 1 ? "新 RStudio" : "新 RStudio \(number)"
        case .terminal:
            return number <= 1 ? "新终端" : "新终端 \(number)"
        case .sftp:
            return number <= 1 ? "SFTP" : "SFTP \(number)"
        }
    }

    func defaultLocalPort(number: Int) -> Int {
        switch self {
        case .jupyter:
            return 8000 + max(0, number - 1)
        case .rstudio:
            return 8008 + max(0, number - 1)
        case .terminal:
            return 8000 + max(0, number - 1)
        case .sftp:
            return 8000 + max(0, number - 1)
        }
    }

    var defaultRemoteHost: String {
        switch self {
        case .jupyter:
            return "127.0.0.1"
        case .rstudio:
            return "localhost"
        case .terminal:
            return "127.0.0.1"
        case .sftp:
            return "127.0.0.1"
        }
    }

    var defaultRemotePort: Int {
        switch self {
        case .jupyter:
            return 8888
        case .rstudio:
            return 8787
        case .terminal:
            return 8888
        case .sftp:
            return 8888
        }
    }

    var defaultHTTPPath: String {
        switch self {
        case .jupyter:
            return "/lab/tree/work"
        case .rstudio:
            return "/"
        case .terminal:
            return "/lab/tree/work"
        case .sftp:
            return "/lab/tree/work"
        }
    }
}

private extension String {
    var normalizedHTTPPath: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    var expandingTildeInPath: String {
        (self as NSString).expandingTildeInPath
    }

    var shellQuoted: String {
        guard !isEmpty else { return "''" }
        if range(of: #"[^A-Za-z0-9_@%+=:,./-]"#, options: .regularExpression) == nil {
            return self
        }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
