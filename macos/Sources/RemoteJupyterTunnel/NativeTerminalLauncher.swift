import AppKit
import Foundation

@MainActor
enum NativeTerminalLauncher {
    static func open(profile: SSHProfile) {
        guard !profile.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        do {
            let scriptURL = try writeExpectScript(password: profile.sshPassword)
            let command = ([scriptURL.path] + profile.terminalArguments(includeBatchMode: profile.sshPassword.isEmpty))
                .map(\.shellQuotedForShell)
                .joined(separator: " ")
            let terminalCommand = "/usr/bin/expect \(command)"
            try runAppleScript(command: terminalCommand)
        } catch {
            NSSound.beep()
        }
    }

    private static func runAppleScript(command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\" to do script \"\(command.appleScriptEscaped)\""
        ]
        try process.run()
    }

    private static func writeExpectScript(password: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteJupyterTunnel", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("native-terminal-\(UUID().uuidString).expect")
        let script = """
        set timeout -1
        set password \(password.tclListLiteral)
        catch {file delete [info script]}
        log_user 1

        spawn /usr/bin/ssh {*}$argv

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

        interact
        catch wait result
        exit [lindex $result 3]
        """

        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

private extension String {
    var shellQuotedForShell: String {
        guard !isEmpty else { return "''" }
        if range(of: #"[^A-Za-z0-9_@%+=:,./-]"#, options: .regularExpression) == nil {
            return self
        }
        return "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var appleScriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    var tclListLiteral: String {
        "{" + replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "}", with: "\\}") + "}"
    }
}
