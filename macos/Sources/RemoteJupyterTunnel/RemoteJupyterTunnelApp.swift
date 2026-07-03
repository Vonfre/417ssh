import AppKit
import SwiftUI

@main
struct RemoteJupyterTunnelApp: App {
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var tunnelManager = TunnelManager()
    @StateObject private var updateManager = UpdateManager()

    init() {
        AppLaunchSanitizer.clearOwnQuarantineIfPossible()
        AppIconInstaller.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(profileStore)
                .environmentObject(tunnelManager)
                .environmentObject(TerminalManager.shared)
                .environmentObject(SFTPManager.shared)
                .environmentObject(updateManager)
                .frame(minWidth: 860, minHeight: 600)
                .task {
                    await updateManager.checkOnStartupIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    tunnelManager.disconnect()
                    TerminalManager.shared.disconnect()
                    SFTPManager.shared.cancel()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建配置") {
                    profileStore.addProfile()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandMenu("更新") {
                Button("检查更新") {
                    Task {
                        await updateManager.checkForUpdates()
                    }
                }
                Button("打开 GitHub Releases") {
                    updateManager.openReleasesPage()
                }
            }
        }

        Settings {
            AppSettingsView()
                .environmentObject(updateManager)
        }
    }
}
