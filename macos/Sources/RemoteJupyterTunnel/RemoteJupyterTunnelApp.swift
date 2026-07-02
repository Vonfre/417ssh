import AppKit
import SwiftUI

@main
struct RemoteJupyterTunnelApp: App {
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var tunnelManager = TunnelManager()

    init() {
        AppIconInstaller.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(profileStore)
                .environmentObject(tunnelManager)
                .environmentObject(TerminalManager.shared)
                .environmentObject(SFTPManager.shared)
                .frame(minWidth: 860, minHeight: 600)
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
        }
    }
}
