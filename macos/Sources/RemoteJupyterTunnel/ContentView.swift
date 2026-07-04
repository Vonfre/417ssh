import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var terminal: TerminalManager
    @EnvironmentObject private var updateManager: UpdateManager

    @State private var reloadToken = 0
    @State private var editingProfileID: UUID?
    @State private var pendingNewProfileID: UUID?
    @State private var selectionBeforeNewProfile: UUID?
    @State private var selectionAfterEditingProfile: UUID?
    @State private var isShowingSettings = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 330)
        } detail: {
            if let profile = store.selectedProfile {
                switch profile.workspaceKind {
                case .jupyter, .rstudio:
                    WebWorkspaceView(
                        profileBox: store.binding(for: profile),
                        reloadToken: $reloadToken,
                        onEdit: {
                            beginEditingProfile(profile.id)
                        }
                    )
                case .terminal:
                    TerminalWorkspaceView(
                        profileBox: store.binding(for: profile),
                        onEdit: {
                            beginEditingProfile(profile.id)
                        }
                    )
                case .sftp:
                    SFTPWorkspaceView(
                        profileBox: store.binding(for: profile),
                        onEdit: {
                            beginEditingProfile(profile.id)
                        },
                        onEditProfile: { profileID in
                            beginEditingProfile(profileID, returnSelectionID: profile.id)
                        },
                        onAddCustomSFTP: {
                            let customProfile = store.addCustomSFTPProfile()
                            pendingNewProfileID = customProfile.id
                            selectionBeforeNewProfile = profile.id
                            selectionAfterEditingProfile = profile.id
                            editingProfileID = customProfile.id
                            return customProfile
                        },
                        onDeleteCustomSFTP: { profileID in
                            store.deleteProfile(id: profileID, fallbackSelectionID: profile.id)
                        }
                    )
                }
            } else {
                EmptyStateView(
                    systemImage: "server.rack",
                    title: "未选择配置",
                    subtitle: "请在左侧选择或新建一个连接配置"
                )
            }
        }
        .sheet(isPresented: isEditingProfile) {
            if
                let editingProfileID,
                let profile = store.profiles.first(where: { $0.id == editingProfileID })
            {
                ProfileEditorView(
                    profile: profile,
                    isNewProfile: pendingNewProfileID == profile.id,
                    onSave: saveEditingProfile,
                    onCancel: cancelEditingProfile
                )
                .frame(minWidth: 560, idealWidth: 620, minHeight: 620, idealHeight: 720)
            } else {
                EmptyStateView(
                    systemImage: "exclamationmark.triangle",
                    title: "配置不存在",
                    subtitle: "这个连接配置可能已经被删除"
                )
                .frame(width: 420, height: 260)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            AppSettingsView()
                .environmentObject(updateManager)
        }
    }

    private var isEditingProfile: Binding<Bool> {
        Binding(
            get: { editingProfileID != nil },
            set: { isPresented in
                if !isPresented {
                    cancelEditingProfile()
                }
            }
        )
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppLogo(size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("417ssh")
                        .font(.headline.weight(.semibold))
                    Text("连接 / 终端 / 文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .background(AppTheme.sidebarHeaderBackground(colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.26), lineWidth: 1)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 14) {
                    ProfileSectionView(
                        title: WorkspaceKind.jupyter.sidebarTitle,
                        count: store.profiles(for: .jupyter).count
                    ) {
                        profileRows(for: .jupyter)
                    }

                    ProfileSectionView(
                        title: WorkspaceKind.rstudio.sidebarTitle,
                        count: store.profiles(for: .rstudio).count
                    ) {
                        profileRows(for: .rstudio)
                    }

                    ProfileSectionView(
                        title: WorkspaceKind.terminal.sidebarTitle,
                        count: store.profiles(for: .terminal).count
                    ) {
                        profileRows(for: .terminal)
                    }

                    ProfileSectionView(
                        title: WorkspaceKind.sftp.sidebarTitle,
                        count: store.profiles(for: .sftp).count
                    ) {
                        profileRows(for: .sftp)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            Divider()
                .opacity(0.45)

            HStack(spacing: 8) {
                Menu {
                    Button {
                        beginNewProfile(.jupyter)
                    } label: {
                        Label("Jupyter 工作区", systemImage: WorkspaceKind.jupyter.systemImage)
                    }

                    Button {
                        beginNewProfile(.rstudio)
                    } label: {
                        Label("RStudio 工作区", systemImage: WorkspaceKind.rstudio.systemImage)
                    }

                    Button {
                        beginNewProfile(.terminal)
                    } label: {
                        Label("终端工作区", systemImage: WorkspaceKind.terminal.systemImage)
                    }

                    Button {
                        beginNewProfile(.sftp)
                    } label: {
                        Label("SFTP 工作区", systemImage: WorkspaceKind.sftp.systemImage)
                    }
                } label: {
                    Label("增加", systemImage: "plus")
                }
                .frame(maxWidth: .infinity)
                .help("新增配置")

                Button(role: .destructive) {
                    store.deleteSelectedProfile()
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(store.profiles.isEmpty)
                .frame(maxWidth: .infinity)
                .help("删除当前配置")

                Button {
                    isShowingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .frame(maxWidth: .infinity)
                .help("打开设置")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(sidebarFooterBackground)
        }
        .background(sidebarBackground)
    }

    private var sidebarBackground: Color {
        AppTheme.sidebarBackground(colorScheme)
    }

    private var sidebarFooterBackground: Color {
        if colorScheme == .dark {
            return Color(nsColor: .textBackgroundColor).opacity(0.30)
        }

        return Color.white.opacity(0.58)
    }

    @ViewBuilder
    private func profileRows(for kind: WorkspaceKind) -> some View {
        let profiles = store.profiles(for: kind)
        if profiles.isEmpty {
            Text(kind.emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } else {
            ForEach(profiles) { profile in
                ProfileListRow(
                    profile: profile,
                    isActive: isProfileActive(profile),
                    isSelected: store.selectedProfileID == profile.id,
                    onSelect: {
                        store.selectedProfileID = profile.id
                    },
                    onEdit: {
                        store.selectedProfileID = profile.id
                        beginEditingProfile(profile.id)
                    }
                )
            }
        }
    }

    private func beginNewProfile(_ kind: WorkspaceKind) {
        selectionBeforeNewProfile = store.selectedProfileID
        let profile = store.addProfile(kind: kind)
        pendingNewProfileID = profile.id
        editingProfileID = profile.id
    }

    private func beginEditingProfile(_ profileID: UUID, returnSelectionID: UUID? = nil) {
        pendingNewProfileID = nil
        selectionBeforeNewProfile = nil
        selectionAfterEditingProfile = returnSelectionID
        editingProfileID = profileID
    }

    private func saveEditingProfile(_ profile: SSHProfile) {
        store.updateProfile(profile)
        store.selectedProfileID = selectionAfterEditingProfile ?? profile.id
        editingProfileID = nil
        pendingNewProfileID = nil
        selectionBeforeNewProfile = nil
        selectionAfterEditingProfile = nil
    }

    private func cancelEditingProfile() {
        if let pendingNewProfileID {
            store.deleteProfile(id: pendingNewProfileID, fallbackSelectionID: selectionBeforeNewProfile)
        } else if let selectionAfterEditingProfile {
            store.selectedProfileID = selectionAfterEditingProfile
        }
        editingProfileID = nil
        pendingNewProfileID = nil
        selectionBeforeNewProfile = nil
        selectionAfterEditingProfile = nil
    }

    private func isProfileActive(_ profile: SSHProfile) -> Bool {
        switch profile.workspaceKind {
        case .jupyter, .rstudio:
            return tunnel.activeProfileID == profile.id && tunnel.status.isRunning
        case .terminal:
            return terminal.isRunning(profile.id)
        case .sftp:
            return false
        }
    }
}

enum AppTheme {
    static let blue = Color(red: 0.18, green: 0.36, blue: 0.78)
    static let teal = Color(red: 0.02, green: 0.54, blue: 0.48)
    static let amber = Color(red: 0.82, green: 0.45, blue: 0.06)

    static func sidebarBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(red: 0.958, green: 0.972, blue: 0.968)
    }

    static func sidebarHeaderBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: .textBackgroundColor).opacity(0.54)
            : Color.white.opacity(0.74)
    }

    static func panelBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(nsColor: .textBackgroundColor).opacity(0.70)
            : Color.white.opacity(0.92)
    }

    static func workspaceColor(_ kind: WorkspaceKind) -> Color {
        switch kind {
        case .jupyter:
            return blue
        case .rstudio:
            return teal
        case .terminal:
            return amber
        case .sftp:
            return Color(red: 0.50, green: 0.36, blue: 0.74)
        }
    }
}

private struct ProfileSectionView<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var content: Content

    init(
        title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.count = count
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: Capsule())

                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 6) {
                content
            }
        }
    }
}

private struct ProfileListRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let profile: SSHProfile
    let isActive: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                ProfileRow(profile: profile, isActive: isActive)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isHovering || isSelected ? .secondary : .tertiary)
            .help("修改配置")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(rowBorder, lineWidth: 1)
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.12)
        }

        if isActive {
            return Color.green.opacity(colorScheme == .dark ? 0.18 : 0.10)
        }

        if isHovering {
            return colorScheme == .dark
                ? Color(nsColor: .textBackgroundColor).opacity(0.88)
                : Color.white.opacity(0.92)
        }

        return colorScheme == .dark
            ? Color(nsColor: .textBackgroundColor).opacity(0.52)
            : Color.white.opacity(0.62)
    }

    private var rowBorder: Color {
        if isSelected {
            return Color.accentColor.opacity(0.20)
        }

        if isHovering || isActive {
            return Color(nsColor: .separatorColor).opacity(0.34)
        }

        return Color(nsColor: .separatorColor).opacity(0.18)
    }
}

private struct ProfileRow: View {
    let profile: SSHProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            WorkspaceIconTile(kind: profile.workspaceKind, isActive: isActive, size: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)

                    if isActive {
                        Text("运行中")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        switch profile.workspaceKind {
        case .jupyter, .rstudio:
            return "\(profile.localPort) -> \(profile.remoteHost):\(profile.remotePort)"
        case .terminal, .sftp:
            return profile.targetAddress.isEmpty ? "未填写目标主机" : profile.targetAddress
        }
    }
}

private struct WorkspaceIconTile: View {
    let kind: WorkspaceKind
    let isActive: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(8, size * 0.25), style: .continuous)
                .fill(color.opacity(isActive ? 0.18 : 0.10))

            Image(systemName: isActive ? "point.3.connected.trianglepath.dotted" : kind.systemImage)
                .font(.system(size: max(12, size * 0.42), weight: .semibold))
                .foregroundStyle(isActive ? color : .secondary)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: min(8, size * 0.25), style: .continuous)
                .stroke(color.opacity(isActive ? 0.24 : 0.12), lineWidth: 1)
        }
    }

    private var color: Color {
        isActive ? .green : AppTheme.workspaceColor(kind)
    }
}

private struct WebWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var tunnel: TunnelManager

    let profileBox: BindingBox<SSHProfile>
    @Binding var reloadToken: Int
    let onEdit: () -> Void

    @State private var selectedTab = WebWorkspaceTab.browser

    private var currentProfile: SSHProfile {
        profileBox.get()
    }

    private var isCurrentProfileActive: Bool {
        tunnel.activeProfileID == currentProfile.id && tunnel.status.isRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            mainPane
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: tunnel.status, perform: { newStatus in
            guard
                newStatus == .connected,
                tunnel.activeProfileID == currentProfile.id
            else {
                return
            }

            selectedTab = .browser
            reloadToken += 1
        })
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                headerTitle
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                headerControls
                    .layoutPriority(2)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    headerTitle
                }

                headerControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.58)
        }
    }

    private var headerTitle: some View {
        HStack(spacing: 10) {
            WorkspaceIconTile(kind: currentProfile.workspaceKind, isActive: isCurrentProfileActive, size: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(currentProfile.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)

                    StatusPill(status: tunnel.status)
                        .layoutPriority(1)
                }

                Text(currentProfile.localURLString)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerControls: some View {
        headerButtons
    }

    private var headerButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                headerActionButtons
            }

            HStack(spacing: 6) {
                headerActionButtons
            }
            .labelStyle(.iconOnly)
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var headerActionButtons: some View {
        Button(action: onEdit) {
            Label("配置", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.bordered)

        if tunnel.portConflict == currentProfile.localPort {
            Button {
                tunnel.closePortConflictAndReconnect(profile: currentProfile)
                selectedTab = .logs
            } label: {
                Label("关闭占用并重连", systemImage: "bolt.horizontal.circle")
            }
            .buttonStyle(.bordered)
        }

        Button {
            reloadToken += 1
            selectedTab = .browser
        } label: {
            Label("刷新", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(!isCurrentProfileActive)

        Button {
            if isCurrentProfileActive {
                tunnel.disconnect()
            } else {
                tunnel.connect(profile: currentProfile, password: currentProfile.sshPassword)
                selectedTab = .browser
                reloadToken += 1
            }
        } label: {
            Label(isCurrentProfileActive ? "断开" : "连接", systemImage: isCurrentProfileActive ? "stop.fill" : "play.fill")
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .buttonStyle(.borderedProminent)
    }

    private var mainPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("视图", selection: $selectedTab) {
                    ForEach(WebWorkspaceTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)

                Spacer(minLength: 0)

                StatusDot(
                    text: workspaceStatusText,
                    color: workspaceStatusColor
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 8)

            Divider()

            ZStack {
                browserPane
                    .opacity(selectedTab == .browser ? 1 : 0)
                    .allowsHitTesting(selectedTab == .browser)

                if selectedTab == .logs {
                    logPane
                        .transition(.opacity)
                }
            }
        }
        .background(AppTheme.panelBackground(colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.48), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.14), value: selectedTab)
    }

    private var workspaceStatusText: String {
        guard tunnel.activeProfileID == currentProfile.id else {
            return "\(currentProfile.workspaceKind.title) 未连接"
        }

        switch tunnel.status {
        case .disconnected:
            return "\(currentProfile.workspaceKind.title) 未连接"
        case .connecting:
            return "\(currentProfile.workspaceKind.title) 正在连接"
        case .connected:
            return "\(currentProfile.workspaceKind.title) 已连接"
        case .failed:
            return "\(currentProfile.workspaceKind.title) 连接失败"
        }
    }

    private var workspaceStatusColor: Color {
        guard tunnel.activeProfileID == currentProfile.id else { return .secondary }

        switch tunnel.status {
        case .disconnected:
            return .secondary
        case .connecting:
            return AppTheme.amber
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }

    private var browserPane: some View {
        ZStack {
            WebWorkspaceBrowserView(
                url: currentProfile.localURL,
                reloadToken: reloadToken,
                onLoadComplete: {
                    tunnel.markConnectedFromBrowser(profileID: currentProfile.id)
                }
            )

            if !isCurrentProfileActive {
                EmptyStateView(
                    systemImage: "network.slash",
                    title: "未连接",
                    subtitle: "连接成功后，这里会显示 \(currentProfile.workspaceKind.title)"
                )
            }
        }
    }

    private var logPane: some View {
        VStack(spacing: 0) {
            HStack {
                Label("SSH 日志", systemImage: "terminal")
                    .font(.headline)

                Spacer()

                Button {
                    tunnel.clearLog()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help("清空日志")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                Text(tunnel.logText.isEmpty ? "暂无日志。" : tunnel.logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ProfileEditorView: View {
    let isNewProfile: Bool
    let onSave: (SSHProfile) -> Void
    let onCancel: () -> Void

    @State private var draftProfile: SSHProfile
    @State private var sshCommandText = ""
    @State private var importMessage: String?
    @State private var importMessageIsError = false

    private var currentProfile: SSHProfile {
        draftProfile
    }

    init(
        profile: SSHProfile,
        isNewProfile: Bool,
        onSave: @escaping (SSHProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.isNewProfile = isNewProfile
        self.onSave = onSave
        self.onCancel = onCancel
        _draftProfile = State(initialValue: profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppLogo(size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isNewProfile ? "新增配置" : "修改配置")
                        .font(.title3.weight(.semibold))
                    Text(currentProfile.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("取消", role: .cancel, action: onCancel)

                Button("完成") {
                    onSave(draftProfile)
                }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 1)
            }
            .padding(12)

            ScrollView {
                settingsForm
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSection(title: "基本配置", systemImage: "person.crop.square") {
                SettingRow("工作区") {
                    Picker("工作区", selection: $draftProfile.workspaceKind) {
                        ForEach(WorkspaceKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.systemImage)
                                .tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }

                labeledTextField("名称", text: $draftProfile.name)
                labeledSecureField("SSH 密码", text: $draftProfile.sshPassword)

                SettingRow("快捷填写") {
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $sshCommandText)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 82)
                                .padding(4)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                                }

                            if sshCommandText.isEmpty {
                                Text("ssh -CNgv -L 8000:remote-host:8888 -J user@jump.example.com:22 user@target-host")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                importFromSSHCommand()
                            } label: {
                                Label("识别并填入", systemImage: "wand.and.stars")
                            }

                            if let importMessage {
                                Text(importMessage)
                                    .font(.caption)
                                    .foregroundStyle(importMessageIsError ? Color.red : Color.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if currentProfile.workspaceKind.isWebWorkspace {
                    SettingRow("\(currentProfile.workspaceKind.title) 地址") {
                        Text(currentProfile.localURLString)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    labeledTextField("页面路径", text: $draftProfile.jupyterPath)
                }
            }

            if currentProfile.workspaceKind.isWebWorkspace {
                SettingsSection(title: "\(currentProfile.workspaceKind.title) 本地转发", systemImage: "arrow.left.arrow.right") {
                    labeledIntField("本地端口", value: $draftProfile.localPort)
                    labeledTextField("远程主机", text: $draftProfile.remoteHost)
                    labeledIntField("远程端口", value: $draftProfile.remotePort)
                    Toggle("启用 -g", isOn: $draftProfile.allowRemoteLocalPortAccess)
                }
            }

            SettingsSection(title: "跳板机", systemImage: "point.3.connected.trianglepath.dotted") {
                labeledTextField("用户名", text: $draftProfile.jumpUser)
                labeledTextField("主机", text: $draftProfile.jumpHost)
                labeledIntField("端口", value: $draftProfile.jumpPort)
            }

            SettingsSection(title: "目标主机", systemImage: "server.rack") {
                labeledTextField("用户名", text: $draftProfile.targetUser)
                labeledTextField("主机", text: $draftProfile.targetHost)
                labeledIntField("SSH 端口", value: $draftProfile.targetPort)
                labeledTextField("密钥文件", text: $draftProfile.identityFile, prompt: "~/.ssh/id_ed25519")
                Toggle("启用压缩 (-C)", isOn: $draftProfile.compressionEnabled)
                Toggle("详细日志 (-v)", isOn: $draftProfile.verboseLogging)
            }

            SettingsSection(title: "连接稳定性", systemImage: "antenna.radiowaves.left.and.right") {
                Toggle("保持长连接", isOn: $draftProfile.keepAliveEnabled)
                labeledIntField("保活间隔", value: $draftProfile.keepAliveInterval)
                labeledIntField("容错次数", value: $draftProfile.keepAliveCountMax)
                Toggle("使用本机 ~/.ssh/config", isOn: $draftProfile.useSSHConfig)
                Text("默认每 30 秒发送一次 SSH 保活包；容错次数越高，短时间网络波动越不容易被判定为断开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("通常建议关闭本机 SSH 配置，避免 ~/.ssh/config 里的 LocalForward 和应用自己的端口转发冲突。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(title: "命令预览", systemImage: "terminal") {
                Text(currentProfile.previewCommand)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func labeledTextField(_ label: String, text: Binding<String>, prompt: String? = nil) -> some View {
        SettingRow(label) {
            TextField(prompt ?? label, text: text)
        }
    }

    private func labeledSecureField(_ label: String, text: Binding<String>) -> some View {
        SettingRow(label) {
            SecureField("连接时自动输入", text: text)
        }
    }

    private func labeledIntField(_ label: String, value: Binding<Int>) -> some View {
        SettingRow(label) {
            TextField(label, value: value, format: .number)
                .frame(maxWidth: 130)
        }
    }

    private func importFromSSHCommand() {
        do {
            var updatedProfile = currentProfile
            try updatedProfile.applySSHCommand(sshCommandText)
            draftProfile = updatedProfile
            importMessage = "已识别并填入当前配置。"
            importMessageIsError = false
        } catch {
            importMessage = error.localizedDescription
            importMessageIsError = true
        }
    }
}

private struct ParsedSSHCommand {
    var targetUser = ""
    var targetHost = ""
    var targetPort: Int?
    var jumpUser = ""
    var jumpHost = ""
    var jumpPort: Int?
    var localPort: Int?
    var remoteHost = ""
    var remotePort: Int?
    var identityFile = ""
    var compressionEnabled = false
    var verboseLogging = false
    var allowRemoteLocalPortAccess = false
}

private enum SSHCommandImportError: LocalizedError {
    case emptyCommand
    case noTarget
    case invalidForward(String)
    case invalidPort(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "SSH 命令为空。"
        case .noTarget:
            return "没有识别到目标主机，例如 user@target-host。"
        case .invalidForward(let value):
            return "无法识别 -L 转发：\(value)"
        case .invalidPort(let value):
            return "端口不是有效数字：\(value)"
        }
    }
}

private extension SSHProfile {
    mutating func applySSHCommand(_ command: String) throws {
        let parsed = try SSHCommandParser.parse(command)
        targetUser = parsed.targetUser
        targetHost = parsed.targetHost
        targetPort = parsed.targetPort ?? 22
        jumpUser = parsed.jumpUser
        jumpHost = parsed.jumpHost
        jumpPort = parsed.jumpPort ?? 22

        if let localPort = parsed.localPort {
            self.localPort = localPort
        }
        if !parsed.remoteHost.isEmpty {
            remoteHost = parsed.remoteHost
        }
        if let remotePort = parsed.remotePort {
            self.remotePort = remotePort
        }
        if !parsed.identityFile.isEmpty {
            identityFile = parsed.identityFile
        }
        compressionEnabled = parsed.compressionEnabled
        verboseLogging = parsed.verboseLogging
        allowRemoteLocalPortAccess = parsed.allowRemoteLocalPortAccess
    }
}

private enum SSHCommandParser {
    static func parse(_ command: String) throws -> ParsedSSHCommand {
        let tokens = try shellSplit(command)
        guard !tokens.isEmpty else { throw SSHCommandImportError.emptyCommand }

        var parsed = ParsedSSHCommand()
        var index = tokens.first?.hasSuffix("ssh") == true || tokens.first?.hasSuffix("ssh.exe") == true ? 1 : 0
        var target: String?

        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                if index < tokens.count {
                    target = tokens[index]
                }
                break
            }

            if !token.hasPrefix("-") || token == "-" {
                target = token
                break
            }

            if token == "-L" {
                index += 1
                guard index < tokens.count else { throw SSHCommandImportError.invalidForward(token) }
                try applyForward(tokens[index], to: &parsed)
            } else if token.hasPrefix("-L"), token.count > 2 {
                try applyForward(String(token.dropFirst(2)), to: &parsed)
            } else if token == "-J" {
                index += 1
                guard index < tokens.count else { throw SSHCommandImportError.noTarget }
                try applyJump(tokens[index], to: &parsed)
            } else if token.hasPrefix("-J"), token.count > 2 {
                try applyJump(String(token.dropFirst(2)), to: &parsed)
            } else if token == "-p" {
                index += 1
                guard index < tokens.count, let port = Int(tokens[index]) else {
                    throw SSHCommandImportError.invalidPort(index < tokens.count ? tokens[index] : token)
                }
                parsed.targetPort = port
            } else if token.hasPrefix("-p"), token.count > 2 {
                let value = String(token.dropFirst(2))
                guard let port = Int(value) else { throw SSHCommandImportError.invalidPort(value) }
                parsed.targetPort = port
            } else if token == "-l" {
                index += 1
                if index < tokens.count {
                    parsed.targetUser = tokens[index]
                }
            } else if token.hasPrefix("-l"), token.count > 2 {
                parsed.targetUser = String(token.dropFirst(2))
            } else if token == "-i" {
                index += 1
                if index < tokens.count {
                    parsed.identityFile = tokens[index]
                }
            } else if token.hasPrefix("-i"), token.count > 2 {
                parsed.identityFile = String(token.dropFirst(2))
            } else if token == "-o" {
                index += 1
                if index < tokens.count {
                    try applySSHOption(tokens[index], to: &parsed)
                }
            } else if token.hasPrefix("-o"), token.count > 2 {
                try applySSHOption(String(token.dropFirst(2)), to: &parsed)
            } else if token == "-F" || optionConsumesNextToken(token) {
                index += 1
            } else if token.hasPrefix("-"), !token.hasPrefix("--") {
                applyCombinedFlags(token, to: &parsed)
            }

            index += 1
        }

        guard let target else { throw SSHCommandImportError.noTarget }
        try applyEndpoint(target, targetPort: parsed.targetPort, user: &parsed.targetUser, host: &parsed.targetHost, port: &parsed.targetPort)
        guard !parsed.targetHost.isEmpty else { throw SSHCommandImportError.noTarget }
        return parsed
    }

    private static func applyCombinedFlags(_ token: String, to parsed: inout ParsedSSHCommand) {
        for character in token.dropFirst() {
            switch character {
            case "C":
                parsed.compressionEnabled = true
            case "v":
                parsed.verboseLogging = true
            case "g":
                parsed.allowRemoteLocalPortAccess = true
            default:
                continue
            }
        }
    }

    private static func optionConsumesNextToken(_ token: String) -> Bool {
        [
            "-B", "-b", "-c", "-D", "-E", "-e", "-I", "-m", "-O", "-Q", "-R", "-S", "-W", "-w"
        ].contains(token)
    }

    private static func applySSHOption(_ value: String, to parsed: inout ParsedSSHCommand) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let key: String
        let optionValue: String
        if let equalsIndex = trimmed.firstIndex(of: "=") {
            key = String(trimmed[..<equalsIndex])
            optionValue = String(trimmed[trimmed.index(after: equalsIndex)...])
        } else if let spaceIndex = trimmed.firstIndex(where: { $0.isWhitespace }) {
            key = String(trimmed[..<spaceIndex])
            optionValue = String(trimmed[trimmed.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return
        }

        switch key.lowercased() {
        case "proxyjump":
            try applyJump(optionValue, to: &parsed)
        case "user":
            parsed.targetUser = optionValue
        case "port":
            guard let port = Int(optionValue) else { throw SSHCommandImportError.invalidPort(optionValue) }
            parsed.targetPort = port
        case "identityfile":
            parsed.identityFile = optionValue
        case "localforward":
            try applyForward(normalizedForwardOption(optionValue), to: &parsed)
        case "compression":
            parsed.compressionEnabled = isTruthySSHOption(optionValue)
        default:
            return
        }
    }

    private static func normalizedForwardOption(_ value: String) -> String {
        let parts = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.count == 2 {
            return "\(parts[0]):\(parts[1])"
        }
        return value
    }

    private static func isTruthySSHOption(_ value: String) -> Bool {
        ["yes", "true", "1", "on"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func applyForward(_ value: String, to parsed: inout ParsedSSHCommand) throws {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3 {
            guard let localPort = Int(parts[0]), let remotePort = Int(parts[2]) else {
                throw SSHCommandImportError.invalidForward(value)
            }
            parsed.localPort = localPort
            parsed.remoteHost = parts[1]
            parsed.remotePort = remotePort
        } else if parts.count == 4 {
            guard let localPort = Int(parts[1]), let remotePort = Int(parts[3]) else {
                throw SSHCommandImportError.invalidForward(value)
            }
            parsed.localPort = localPort
            parsed.remoteHost = parts[2]
            parsed.remotePort = remotePort
        } else {
            throw SSHCommandImportError.invalidForward(value)
        }
    }

    private static func applyJump(_ value: String, to parsed: inout ParsedSSHCommand) throws {
        try applyEndpoint(value, targetPort: 22, user: &parsed.jumpUser, host: &parsed.jumpHost, port: &parsed.jumpPort)
    }

    private static func applyEndpoint(
        _ value: String,
        targetPort: Int?,
        user: inout String,
        host: inout String,
        port: inout Int?
    ) throws {
        var endpoint = value
        if let atIndex = endpoint.lastIndex(of: "@") {
            user = String(endpoint[..<atIndex])
            endpoint = String(endpoint[endpoint.index(after: atIndex)...])
        }

        if let colonIndex = endpoint.lastIndex(of: ":") {
            let portText = String(endpoint[endpoint.index(after: colonIndex)...])
            if !portText.isEmpty, let parsedPort = Int(portText) {
                host = String(endpoint[..<colonIndex])
                port = parsedPort
                return
            } else if !portText.isEmpty {
                throw SSHCommandImportError.invalidPort(portText)
            }
        }

        host = endpoint
        port = targetPort ?? port
    }

    private static func shellSplit(_ command: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        for character in command {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
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

            if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }
}

private enum WebWorkspaceTab: String, CaseIterable, Identifiable {
    case browser
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser:
            return "网页"
        case .logs:
            return "日志"
        }
    }

    var systemImage: String {
        switch self {
        case .browser:
            return "safari"
        case .logs:
            return "doc.text.magnifyingglass"
        }
    }
}

private struct TerminalFileSidebarState: Equatable {
    var selectedEntry: RemoteFileEntry?
    var remotePathText = "."
    var isVisible = false
    var automaticallySyncsTerminalDirectory = false
}

@MainActor
private final class TerminalFileSidebarStateStore: ObservableObject {
    static let shared = TerminalFileSidebarStateStore()

    @Published private var states: [UUID: TerminalFileSidebarState] = [:]
    private var sftpManagers: [UUID: SFTPManager] = [:]

    private init() {}

    func state(for profileID: UUID) -> TerminalFileSidebarState {
        states[profileID] ?? TerminalFileSidebarState()
    }

    func update(_ profileID: UUID, _ mutate: (inout TerminalFileSidebarState) -> Void) {
        var state = states[profileID] ?? TerminalFileSidebarState()
        mutate(&state)
        states[profileID] = state
    }

    func sftpManager(for profileID: UUID) -> SFTPManager {
        if let manager = sftpManagers[profileID] {
            return manager
        }

        let manager = SFTPManager()
        sftpManagers[profileID] = manager
        return manager
    }
}

private struct TerminalWorkspaceView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var terminal: TerminalManager

    let profileBox: BindingBox<SSHProfile>
    let onEdit: () -> Void

    @StateObject private var fileSidebarStateStore = TerminalFileSidebarStateStore.shared

    private var currentProfile: SSHProfile {
        profileBox.get()
    }

    private var fileSidebarState: TerminalFileSidebarState {
        fileSidebarStateStore.state(for: currentProfile.id)
    }

    private var fileSidebarSFTP: SFTPManager {
        fileSidebarStateStore.sftpManager(for: currentProfile.id)
    }

    private var selectedEntry: Binding<RemoteFileEntry?> {
        Binding(
            get: { fileSidebarStateStore.state(for: currentProfile.id).selectedEntry },
            set: { newValue in
                fileSidebarStateStore.update(currentProfile.id) { $0.selectedEntry = newValue }
            }
        )
    }

    private var remotePathText: Binding<String> {
        Binding(
            get: { fileSidebarStateStore.state(for: currentProfile.id).remotePathText },
            set: { newValue in
                fileSidebarStateStore.update(currentProfile.id) { $0.remotePathText = newValue }
            }
        )
    }

    private var automaticallySyncsTerminalDirectory: Binding<Bool> {
        Binding(
            get: { fileSidebarStateStore.state(for: currentProfile.id).automaticallySyncsTerminalDirectory },
            set: { newValue in
                fileSidebarStateStore.update(currentProfile.id) { $0.automaticallySyncsTerminalDirectory = newValue }
            }
        )
    }

    private var isCurrentProfileTerminal: Bool {
        terminal.isRunning(currentProfile.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HSplitView {
                terminalPane
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                if fileSidebarState.isVisible {
                    RemoteFileBrowserPane(
                        profile: currentProfile,
                        availableProfiles: store.profiles,
                        selectedEntry: selectedEntry,
                        remotePathText: remotePathText,
                        terminalProfileID: currentProfile.id,
                        automaticallySyncsTerminalDirectory: automaticallySyncsTerminalDirectory
                    )
                    .environmentObject(fileSidebarSFTP)
                    .frame(minWidth: 360, idealWidth: 520, maxWidth: 780, maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if fileSidebarState.remotePathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fileSidebarStateStore.update(currentProfile.id) {
                    $0.remotePathText = fileSidebarSFTP.activeProfileID == currentProfile.id ? fileSidebarSFTP.currentRemotePath : "."
                }
            }
        }
        .onChange(of: terminal.statusByProfileID) { _ in
            guard
                terminal.status(for: currentProfile.id) == .connected
            else {
                return
            }

            refreshFiles()
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                headerTitle
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                headerButtons
                    .layoutPriority(2)
            }

            VStack(alignment: .leading, spacing: 8) {
                headerTitle
                headerButtons
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.86))
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.58)
        }
    }

    private var headerTitle: some View {
        HStack(spacing: 10) {
            AppLogo(size: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(currentProfile.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)

                    StatusDot(text: terminalStatusText, color: terminalStatusColor)
                }

                Text(currentProfile.targetAddress.isEmpty ? "未填写目标主机" : currentProfile.targetAddress)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                terminalActionButtons
            }

            HStack(spacing: 6) {
                terminalActionButtons
            }
            .labelStyle(.iconOnly)
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var terminalActionButtons: some View {
        Button(action: onEdit) {
            Label("配置", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.bordered)

        Button(action: toggleFileSidebar) {
            Label(fileSidebarState.isVisible ? "隐藏文件" : "文件", systemImage: "sidebar.right")
        }
        .buttonStyle(.bordered)
        .disabled(currentProfile.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        if fileSidebarState.isVisible {
            Button(action: refreshFiles) {
                Label("刷新文件", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(fileSidebarSFTP.status == .running || currentProfile.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        Button {
            NativeTerminalLauncher.open(profile: currentProfile)
        } label: {
            Label("原生终端", systemImage: "macwindow")
        }
        .buttonStyle(.bordered)
        .disabled(currentProfile.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button {
            if isCurrentProfileTerminal {
                terminal.disconnect(profileID: currentProfile.id)
            } else {
                terminal.connect(profile: currentProfile)
            }
        } label: {
            Label(isCurrentProfileTerminal ? "断开终端" : "连接终端", systemImage: isCurrentProfileTerminal ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.borderedProminent)
    }

    private var terminalPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(terminalTitle, systemImage: "terminal")
                    .font(.headline)
                    .lineLimit(1)

                StatusDot(text: isCurrentProfileTerminal ? "可直接输入" : "未连接", color: isCurrentProfileTerminal ? .green : .secondary)

                Spacer()

                Button {
                    terminal.clear(profileID: currentProfile.id)
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help("清空终端输出")

                Button {
                    terminal.sendControlC(profileID: currentProfile.id)
                } label: {
                    Label("中断", systemImage: "command")
                }
                .disabled(!isCurrentProfileTerminal)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ZStack {
                TerminalConsoleView(terminal: terminal, profileID: currentProfile.id)

                if !isCurrentProfileTerminal {
                    EmptyStateView(
                        systemImage: "terminal",
                        title: "终端未连接",
                        subtitle: "点击“连接终端”后，这里就是完整 PTY 终端"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.92))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.48), lineWidth: 1)
        }
    }

    private var terminalTitle: String {
        terminal.title(for: currentProfile.id)
    }

    private var terminalStatusColor: Color {
        switch terminal.status(for: currentProfile.id) {
        case .disconnected:
            return .secondary
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }

    private var terminalStatusText: String {
        terminal.status(for: currentProfile.id).label
    }

    private func refreshFiles() {
        fileSidebarSFTP.refreshDirectory(profile: currentProfile, path: fileSidebarState.remotePathText)
    }

    private func toggleFileSidebar() {
        fileSidebarStateStore.update(currentProfile.id) {
            $0.isVisible.toggle()
        }
        if fileSidebarStateStore.state(for: currentProfile.id).isVisible {
            refreshFiles()
        }
    }
}

private struct SFTPWorkspacePaneState: Identifiable, Equatable {
    let id = UUID()
    var profileID: UUID?
    var selectedEntry: RemoteFileEntry?
    var remotePathText = "."
}

private enum SFTPSide: String, CaseIterable {
    case left = "A"
    case right = "B"
}

private struct SFTPSideState: Identifiable, Equatable {
    let id = UUID()
    var sourceKey: String?
    var title: String
    var selectedEntry: RemoteFileEntry?
    var pathText: String
    var filterText = ""
    var sortColumn: RemoteFileSortColumn = .name
    var sortAscending = true

    static func local() -> SFTPSideState {
        SFTPSideState(sourceKey: SFTPSource.localKey, title: "127.0.0.1", pathText: NSHomeDirectory())
    }

    static func empty() -> SFTPSideState {
        SFTPSideState(sourceKey: nil, title: "选择主机", pathText: NSHomeDirectory())
    }
}

private struct SFTPTabState: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var left: SFTPSideState
    var right: SFTPSideState

    static func first() -> SFTPTabState {
        SFTPTabState(title: "SFTP 1", left: .local(), right: .empty())
    }

    static func empty(number: Int) -> SFTPTabState {
        SFTPTabState(title: "SFTP \(number)", left: .local(), right: .empty())
    }
}

@MainActor
private final class SFTPWorkspaceStateStore: ObservableObject {
    static let shared = SFTPWorkspaceStateStore()

    @Published var tabs: [SFTPTabState] = [.first()]
    @Published var selectedTabID: UUID?
    var sideManagers: [UUID: SFTPManager] = [:]

    private init() {
        ensureManagers()
        selectedTabID = tabs.first?.id
    }

    func ensureManagers() {
        for tab in tabs {
            for sideID in [tab.left.id, tab.right.id] where sideManagers[sideID] == nil {
                sideManagers[sideID] = SFTPManager()
            }
        }
    }

    func removeManager(for sideID: UUID) {
        sideManagers[sideID]?.cancel()
        sideManagers.removeValue(forKey: sideID)
    }
}

private struct SFTPSource: Identifiable, Equatable {
    static let localKey = "local"

    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let profile: SSHProfile?

    var isLocal: Bool {
        id == Self.localKey
    }

    static var local: SFTPSource {
        SFTPSource(
            id: localKey,
            title: "127.0.0.1",
            subtitle: "本地主机",
            systemImage: "desktopcomputer",
            profile: nil
        )
    }

    static func profile(_ profile: SSHProfile) -> SFTPSource {
        SFTPSource(
            id: "profile:\(profile.id.uuidString)",
            title: profile.name,
            subtitle: profile.targetAddress.isEmpty ? "未填写目标主机" : profile.targetAddress,
            systemImage: profile.workspaceKind == .terminal ? "terminal" : "server.rack",
            profile: profile
        )
    }
}

private struct SFTPWorkspaceView: View {
    @EnvironmentObject private var store: ProfileStore

    let profileBox: BindingBox<SSHProfile>
    let onEdit: () -> Void
    let onEditProfile: (UUID) -> Void
    let onAddCustomSFTP: () -> SSHProfile
    let onDeleteCustomSFTP: (UUID) -> Void

    @StateObject private var workspaceState = SFTPWorkspaceStateStore.shared

    private var currentProfile: SSHProfile {
        profileBox.get()
    }

    private var sources: [SFTPSource] {
        let remoteSources = store.profiles
            .filter { profile in
                profile.workspaceKind == .terminal
                    || (profile.workspaceKind == .sftp && profile.id != currentProfile.id)
            }
            .map(SFTPSource.profile)
        return [.local] + remoteSources
    }

    private var activeTab: SFTPTabState? {
        if let selectedTabID = workspaceState.selectedTabID,
           let tab = workspaceState.tabs.first(where: { $0.id == selectedTabID }) {
            return tab
        }
        return workspaceState.tabs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar

            Divider()

            if let activeTab {
                SFTPTabContentView(
                    tab: tabBinding(activeTab.id),
                    sources: sources,
                    workspaceProfileID: currentProfile.id,
                    availableProfiles: sources.compactMap(\.profile),
                    leftSFTP: manager(for: activeTab.left.id),
                    rightSFTP: manager(for: activeTab.right.id),
                    onSelectSource: { side, source in
                        select(source, for: activeTab.id, side: side)
                    },
                    onClearSource: { side in
                        clearSource(for: activeTab.id, side: side)
                    },
                    onEditProfile: onEditProfile,
                    onAddCustomSFTP: {
                        let profile = onAddCustomSFTP()
                        let source = SFTPSource.profile(profile)
                        select(source, for: activeTab.id, side: $0)
                    },
                    onDeleteCustomSFTP: { profileID in
                        onDeleteCustomSFTP(profileID)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: ensureTabs)
        .onChange(of: store.profiles) { _ in
            normalizeTabs()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            WorkspaceIconTile(kind: .sftp, isActive: false, size: 30)

            Text("SFTP")
                .font(.headline.weight(.semibold))
                .lineLimit(1)

            StatusDot(text: "\(workspaceState.tabs.count) 个标签", color: AppTheme.workspaceColor(.sftp))

            Text("每个标签包含 A/B 两栏，可左右拖拽传输")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: onEdit) {
                Label("配置", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial)
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(workspaceState.tabs) { tab in
                    sftpTabButton(tab)
                }

                Button(action: addTab) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("新增 SFTP 标签")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
    }

    private func sftpTabButton(_ tab: SFTPTabState) -> some View {
        let isSelected = activeTab?.id == tab.id
        return HStack(spacing: 6) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 12, weight: .semibold))

            Text(tabTitle(tab))
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            if workspaceState.tabs.count > 1 {
                Button {
                    closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            workspaceState.selectedTabID = tab.id
        }
    }

    private func tabBinding(_ tabID: UUID) -> Binding<SFTPTabState> {
        Binding(
            get: {
                workspaceState.tabs.first(where: { $0.id == tabID }) ?? workspaceState.tabs[0]
            },
            set: { updatedTab in
                guard let index = workspaceState.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                workspaceState.tabs[index] = updatedTab
            }
        )
    }

    private func ensureTabs() {
        if workspaceState.tabs.isEmpty {
            workspaceState.tabs = [.first()]
        }
        workspaceState.selectedTabID = workspaceState.selectedTabID ?? workspaceState.tabs.first?.id
        workspaceState.ensureManagers()
        normalizeTabs()
    }

    private func normalizeTabs() {
        let sourceIDs = Set(sources.map(\.id))
        for index in workspaceState.tabs.indices {
            normalizeSide(&workspaceState.tabs[index].left, sourceIDs: sourceIDs)
            normalizeSide(&workspaceState.tabs[index].right, sourceIDs: sourceIDs)
        }
        workspaceState.ensureManagers()
        let sideIDs = Set(workspaceState.tabs.flatMap { [$0.left.id, $0.right.id] })
        for managerID in Array(workspaceState.sideManagers.keys) where !sideIDs.contains(managerID) {
            workspaceState.removeManager(for: managerID)
        }
    }

    private func addTab() {
        let tab = SFTPTabState.empty(number: workspaceState.tabs.count + 1)
        workspaceState.tabs.append(tab)
        workspaceState.sideManagers[tab.left.id] = SFTPManager()
        workspaceState.sideManagers[tab.right.id] = SFTPManager()
        workspaceState.selectedTabID = tab.id
    }

    private func closeTab(_ tabID: UUID) {
        guard workspaceState.tabs.count > 1 else { return }
        guard let index = workspaceState.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = workspaceState.tabs[index]
        workspaceState.tabs.remove(at: index)
        for sideID in [tab.left.id, tab.right.id] {
            workspaceState.removeManager(for: sideID)
        }
        if workspaceState.selectedTabID == tabID {
            workspaceState.selectedTabID = workspaceState.tabs[min(index, workspaceState.tabs.count - 1)].id
        }
    }

    private func select(_ source: SFTPSource, for tabID: UUID, side: SFTPSide) {
        guard let index = workspaceState.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        var pane = paneState(for: side, in: workspaceState.tabs[index])
        pane.sourceKey = source.id
        pane.title = source.title
        pane.selectedEntry = nil
        pane.pathText = source.isLocal ? NSHomeDirectory() : "."
        pane.filterText = ""
        setPaneState(pane, for: side, in: index)

        if workspaceState.sideManagers[pane.id] == nil {
            workspaceState.sideManagers[pane.id] = SFTPManager()
        }
        workspaceState.sideManagers[pane.id]?.cancel()
        workspaceState.sideManagers[pane.id]?.clear()
    }

    private func clearSource(for tabID: UUID, side: SFTPSide) {
        guard let index = workspaceState.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        var pane = paneState(for: side, in: workspaceState.tabs[index])
        pane.sourceKey = nil
        pane.title = "选择主机"
        pane.selectedEntry = nil
        pane.pathText = NSHomeDirectory()
        pane.filterText = ""
        setPaneState(pane, for: side, in: index)
        workspaceState.sideManagers[pane.id]?.cancel()
        workspaceState.sideManagers[pane.id]?.clear()
    }

    private func manager(for sideID: UUID) -> SFTPManager {
        workspaceState.sideManagers[sideID] ?? SFTPManager.shared
    }

    private func normalizeSide(_ side: inout SFTPSideState, sourceIDs: Set<String>) {
        if let sourceKey = side.sourceKey, !sourceIDs.contains(sourceKey) {
            side.sourceKey = nil
            side.title = "选择主机"
            side.selectedEntry = nil
            side.pathText = NSHomeDirectory()
        }
    }

    private func paneState(for side: SFTPSide, in tab: SFTPTabState) -> SFTPSideState {
        side == .left ? tab.left : tab.right
    }

    private func setPaneState(_ pane: SFTPSideState, for side: SFTPSide, in index: Int) {
        if side == .left {
            workspaceState.tabs[index].left = pane
        } else {
            workspaceState.tabs[index].right = pane
        }
    }

    private func tabTitle(_ tab: SFTPTabState) -> String {
        "\(tab.title)  A:\(tab.left.title)  B:\(tab.right.title)"
    }
}

private struct SFTPTabContentView: View {
    @Binding var tab: SFTPTabState

    let sources: [SFTPSource]
    let workspaceProfileID: UUID
    let availableProfiles: [SSHProfile]
    @ObservedObject var leftSFTP: SFTPManager
    @ObservedObject var rightSFTP: SFTPManager
    let onSelectSource: (SFTPSide, SFTPSource) -> Void
    let onClearSource: (SFTPSide) -> Void
    let onEditProfile: (UUID) -> Void
    let onAddCustomSFTP: (SFTPSide) -> Void
    let onDeleteCustomSFTP: (UUID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            SFTPSideContentView(
                side: .left,
                pane: $tab.left,
                sources: sources,
                workspaceProfileID: workspaceProfileID,
                availableProfiles: availableProfiles,
                sftp: leftSFTP,
                onSelectSource: { source in onSelectSource(.left, source) },
                onClearSource: { onClearSource(.left) },
                onEditProfile: onEditProfile,
                onAddCustomSFTP: { onAddCustomSFTP(.left) },
                onDeleteCustomSFTP: onDeleteCustomSFTP
            )

            Divider()

            SFTPSideContentView(
                side: .right,
                pane: $tab.right,
                sources: sources,
                workspaceProfileID: workspaceProfileID,
                availableProfiles: availableProfiles,
                sftp: rightSFTP,
                onSelectSource: { source in onSelectSource(.right, source) },
                onClearSource: { onClearSource(.right) },
                onEditProfile: onEditProfile,
                onAddCustomSFTP: { onAddCustomSFTP(.right) },
                onDeleteCustomSFTP: onDeleteCustomSFTP
            )
        }
    }
}

private struct SFTPSideContentView: View {
    let side: SFTPSide
    @Binding var pane: SFTPSideState

    let sources: [SFTPSource]
    let workspaceProfileID: UUID
    let availableProfiles: [SSHProfile]
    @ObservedObject var sftp: SFTPManager
    let onSelectSource: (SFTPSource) -> Void
    let onClearSource: () -> Void
    let onEditProfile: (UUID) -> Void
    let onAddCustomSFTP: () -> Void
    let onDeleteCustomSFTP: (UUID) -> Void

    private var selectedSource: SFTPSource? {
        guard let sourceKey = pane.sourceKey else { return nil }
        return sources.first { $0.id == sourceKey }
    }

    var body: some View {
        VStack(spacing: 0) {
            sideHeader
            Divider()

            Group {
                if let source = selectedSource {
                    if source.isLocal {
                        LocalFileBrowserPane(
                            pane: $pane,
                            availableProfiles: availableProfiles
                        )
                    } else if let profile = source.profile {
                        RemoteSFTPTabPane(
                            pane: $pane,
                            profile: profile,
                            availableProfiles: availableProfiles,
                            sftp: sftp
                        )
                    } else {
                        hostPicker
                    }
                } else {
                    hostPicker
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sideHeader: some View {
        HStack(spacing: 8) {
            Text(side.rawValue)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(pane.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if pane.sourceKey != nil {
                Button {
                    onClearSource()
                } label: {
                    Label("切换 Host", systemImage: "rectangle.2.swap")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var hostPicker: some View {
        SFTPHostPickerView(
            side: side,
            sources: sources,
            selectedSourceID: pane.sourceKey,
            workspaceProfileID: workspaceProfileID,
            onSelect: onSelectSource,
            onEditProfile: onEditProfile,
            onAddCustomSFTP: onAddCustomSFTP,
            onDeleteCustomSFTP: onDeleteCustomSFTP
        )
    }
}

private struct SFTPHostPickerView: View {
    let side: SFTPSide
    let sources: [SFTPSource]
    let selectedSourceID: String?
    let workspaceProfileID: UUID
    let onSelect: (SFTPSource) -> Void
    let onEditProfile: (UUID) -> Void
    let onAddCustomSFTP: () -> Void
    let onDeleteCustomSFTP: (UUID) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 14, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("Hosts \(side.rawValue)")
                        .font(.title3.weight(.bold))

                    Spacer(minLength: 0)

                    Button {
                        onAddCustomSFTP()
                    } label: {
                        Label("新增自定义 SFTP", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(sources) { source in
                        hostCard(source)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(red: 0.93, green: 0.96, blue: 0.96))
    }

    private func hostCard(_ source: SFTPSource) -> some View {
        let isSelected = selectedSourceID == source.id
        let canManage = source.profile?.workspaceKind == .sftp && source.profile?.id != workspaceProfileID
        return HStack(spacing: 8) {
            Button {
                onSelect(source)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: source.systemImage)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 40, height: 40)
                        .background(source.isLocal ? Color.black : Color.orange, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(source.subtitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            if canManage, let profileID = source.profile?.id {
                VStack(spacing: 6) {
                    Button {
                        onEditProfile(profileID)
                    } label: {
                        Image(systemName: "pencil")
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("编辑这个自定义 SFTP")

                    Button {
                        confirmDelete(profileID: profileID, title: source.title)
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("删除这个自定义 SFTP")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 78)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: isSelected ? 2 : 1)
        }
    }

    private func confirmDelete(profileID: UUID, title: String) {
        let alert = NSAlert()
        alert.messageText = "删除自定义 SFTP"
        alert.informativeText = "确定删除“\(title)”吗？这个操作只会删除 Host 配置，不会删除服务器上的文件。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDeleteCustomSFTP(profileID)
    }
}

private struct RemoteSFTPTabPane: View {
    @Binding var pane: SFTPSideState

    let profile: SSHProfile
    let availableProfiles: [SSHProfile]
    @ObservedObject var sftp: SFTPManager

    private var canConnect: Bool {
        !profile.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if canConnect {
                RemoteFileBrowserPane(
                    profile: profile,
                    availableProfiles: availableProfiles,
                    selectedEntry: $pane.selectedEntry,
                    remotePathText: $pane.pathText,
                    terminalProfileID: nil,
                    automaticallySyncsTerminalDirectory: .constant(false)
                )
                .environmentObject(sftp)
            } else {
                EmptyStateView(
                    systemImage: "server.rack",
                    title: "未填写目标主机",
                    subtitle: "点右上角“配置”，或切换到已有终端工作区"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .onAppear(perform: refreshIfNeeded)
    }

    private func refreshIfNeeded() {
        guard canConnect else { return }
        if pane.pathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pane.pathText = "."
        }
        guard sftp.activeProfileID == nil else { return }
        sftp.refreshDirectory(profile: profile, path: pane.pathText)
    }
}

private struct LocalFileBrowserPane: View {
    @Binding var pane: SFTPSideState

    let availableProfiles: [SSHProfile]

    @State private var entries: [RemoteFileEntry] = []
    @State private var statusText = "本地文件"
    @State private var isDropTarget = false
    @StateObject private var transferSFTP = SFTPManager()

    private var displayedEntries: [RemoteFileEntry] {
        sortedEntries(filteredEntries)
    }

    private var filteredEntries: [RemoteFileEntry] {
        let trimmed = pane.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var isRootPath: Bool {
        let url = URL(fileURLWithPath: expandedLocalPath(pane.pathText)).standardizedFileURL
        return url.path == url.deletingLastPathComponent().path
    }

    private var canMutateSelectedEntry: Bool {
        guard let selectedEntry = pane.selectedEntry else { return false }
        return selectedEntry.name != ".."
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Text("127.0.0.1")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    StatusDot(text: localStatusLabel, color: statusColor)
                        .frame(width: 94, alignment: .leading)

                    Spacer()

                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                        TextField("筛选", text: $pane.filterText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: 132)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Menu {
                        Button(action: refresh) {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        Button(action: goParent) {
                            Label("上级文件夹", systemImage: "arrow.up")
                        }
                        .disabled(isRootPath)
                        Divider()
                        Button(action: chooseAndCopyHere) {
                            Label("复制到当前目录", systemImage: "arrow.up.doc")
                        }
                        Button(action: copySelectedToFolder) {
                            Label("复制选中项到...", systemImage: "arrow.down.doc")
                        }
                        .disabled(!canMutateSelectedEntry)
                        Button(action: createFolder) {
                            Label("新建文件夹", systemImage: "folder.badge.plus")
                        }
                        Divider()
                        Button(action: copySelectedToPath) {
                            Label("复制到目标目录", systemImage: "doc.on.doc")
                        }
                        .disabled(!canMutateSelectedEntry)
                        Button(action: renameSelected) {
                            Label("重命名", systemImage: "pencil")
                        }
                        .disabled(!canMutateSelectedEntry)
                        Button(action: editSelectedPermissions) {
                            Label("修改权限", systemImage: "lock.open")
                        }
                        .disabled(!canMutateSelectedEntry)
                        Button(role: .destructive, action: deleteSelected) {
                            Label("删除", systemImage: "trash")
                        }
                        .disabled(!canMutateSelectedEntry)
                    } label: {
                        Label("操作", systemImage: "ellipsis.circle")
                    }
                }

                HStack(spacing: 8) {
                    Button(action: goParent) {
                        Image(systemName: "chevron.left")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("返回上级")
                    .disabled(isRootPath)

                    Button(action: goParent) {
                        Image(systemName: "chevron.up")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("上级文件夹")
                    .disabled(isRootPath)

                    HStack(spacing: 6) {
                        TextField("本地路径，例如 ~/Downloads", text: $pane.pathText)
                            .textFieldStyle(.plain)
                            .font(.caption.weight(.medium))
                            .onSubmit {
                                openPath(pane.pathText)
                            }

                        Button {
                            openPath(pane.pathText)
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("跳转到输入的本地路径")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(Color(red: 0.965, green: 0.982, blue: 0.988))

            Divider()

            ZStack(alignment: .top) {
                RemoteFileTableView(
                    entries: displayedEntries,
                    profileID: pane.id,
                    selectedEntry: $pane.selectedEntry,
                    sortColumn: $pane.sortColumn,
                    sortAscending: $pane.sortAscending,
                    currentPath: normalizedCurrentPath,
                    loadingPath: nil,
                    canNavigate: true,
                    canMutate: true,
                    localFileDragEnabled: true,
                    onOpen: open,
                    onContextAction: handleContextAction
                )
                .opacity(displayedEntries.isEmpty ? 0 : 1)

                if displayedEntries.isEmpty {
                    EmptyStateView(
                        systemImage: "folder",
                        title: "还没有文件列表",
                        subtitle: pane.filterText.isEmpty ? "当前目录为空，或没有读取权限" : "没有匹配的文件"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if isDropTarget {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        Label("松开以复制到当前目录", systemImage: "arrow.down.doc.fill")
                            .font(.headline)
                            .padding(18)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
            }
        }
        .onDrop(of: [UTType.fileURL.identifier, RemoteFileDragPayload.typeIdentifier], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .onAppear {
            if pane.pathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pane.pathText = NSHomeDirectory()
            }
            loadDirectory(pane.pathText)
        }
        .onChange(of: pane.pathText) { newPath in
            loadDirectory(newPath)
        }
        .onChange(of: transferSFTP.status) { status in
            if status == .completed {
                loadDirectory(pane.pathText)
            }
        }
    }

    private var normalizedCurrentPath: String {
        expandedLocalPath(pane.pathText)
    }

    private var localStatusLabel: String {
        switch transferSFTP.status {
        case .running:
            return "传输中"
        case .failed:
            return "传输失败"
        default:
            return statusText
        }
    }

    private var statusColor: Color {
        switch transferSFTP.status {
        case .running:
            return .orange
        case .failed:
            return .red
        case .completed:
            return .green
        case .idle:
            return .secondary
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.26))
    }

    private var footerText: String {
        if transferSFTP.status == .running {
            return transferSFTP.transferProgressText.isEmpty ? "正在接收远程文件..." : transferSFTP.transferProgressText
        }
        if case .failed(let message) = transferSFTP.status {
            return message
        }
        return "\(displayedEntries.count) 个项目"
    }

    private func refresh() {
        loadDirectory(pane.pathText)
    }

    private func sortedEntries(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        let parentEntries = entries.filter { $0.name == ".." }
        let regularEntries = entries.filter { $0.name != ".." }
        let sorted = regularEntries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }

            let result: ComparisonResult
            switch pane.sortColumn {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name)
            case .modified:
                result = lhs.modified.localizedStandardCompare(rhs.modified)
            case .size:
                if lhs.sizeBytes == rhs.sizeBytes {
                    result = lhs.name.localizedStandardCompare(rhs.name)
                } else {
                    result = lhs.sizeBytes < rhs.sizeBytes ? .orderedAscending : .orderedDescending
                }
            case .kind:
                result = lhs.kind.localizedStandardCompare(rhs.kind)
            }

            if result == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return pane.sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
        return parentEntries + sorted
    }

    private func open(_ entry: RemoteFileEntry) {
        if entry.isDirectory {
            pane.selectedEntry = nil
            pane.pathText = entry.path
            loadDirectory(entry.path)
            return
        }

        pane.selectedEntry = entry
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
    }

    private func handleContextAction(_ action: RemoteFileContextAction, entry: RemoteFileEntry?) {
        switch action {
        case .open:
            if let entry { open(entry) }
        case .download:
            if let entry { copyToFolder(entry) }
        case .uploadHere:
            chooseAndCopyHere()
        case .copyToDirectory:
            if let entry { copyToTargetDirectory(entry) }
        case .rename:
            if let entry { rename(entry) }
        case .delete:
            if let entry { delete(entry) }
        case .refresh:
            refresh()
        case .newFolder:
            createFolder()
        case .editPermissions:
            if let entry { editPermissions(entry) }
        }
    }

    private func openPath(_ path: String) {
        let expanded = expandedLocalPath(path)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            showAlert(title: "路径不存在", message: expanded)
            return
        }
        if isDirectory.boolValue {
            pane.selectedEntry = nil
            pane.pathText = expanded
            loadDirectory(expanded)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
        }
    }

    private func goParent() {
        let url = URL(fileURLWithPath: expandedLocalPath(pane.pathText)).standardizedFileURL
        let parentURL = url.deletingLastPathComponent()
        guard parentURL.path != url.path else { return }
        pane.selectedEntry = nil
        pane.pathText = parentURL.path
        loadDirectory(parentURL.path)
    }

    private func loadDirectory(_ path: String) {
        let fileManager = FileManager.default
        let expandedPath = expandedLocalPath(path)
        let directoryURL = URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
        var isDirectory = ObjCBool(false)

        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            entries = []
            statusText = "路径不可用"
            return
        }

        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            let childURLs = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: Array(keys), options: [])
            var nextEntries: [RemoteFileEntry] = []

            let parentURL = directoryURL.deletingLastPathComponent()
            if parentURL.path != directoryURL.path {
                nextEntries.append(
                    RemoteFileEntry(
                        name: "..",
                        path: parentURL.path,
                        isDirectory: true,
                        isLink: false,
                        permissions: "上级目录",
                        size: "",
                        sizeBytes: -1,
                        modified: ""
                    )
                )
            }

            for childURL in childURLs {
                if let entry = localEntry(for: childURL) {
                    nextEntries.append(entry)
                }
            }

            entries = nextEntries
            pane.pathText = directoryURL.path
            statusText = "本地文件"
        } catch {
            entries = []
            statusText = "读取失败"
            showAlert(title: "读取本地目录失败", message: error.localizedDescription)
        }
    }

    private func localEntry(for url: URL) -> RemoteFileEntry? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let isLink = values?.isSymbolicLink ?? false
        let isDirectory = values?.isDirectory ?? false
        let sizeBytes = isDirectory ? Int64(0) : Int64(values?.fileSize ?? 0)
        let modifiedDate = values?.contentModificationDate ?? attributes?[.modificationDate] as? Date
        let mode = (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? 0

        return RemoteFileEntry(
            name: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            path: url.path,
            isDirectory: isDirectory,
            isLink: isLink,
            permissions: permissionString(mode: mode, isDirectory: isDirectory, isLink: isLink),
            size: isDirectory ? "--" : Self.byteFormatter.string(fromByteCount: sizeBytes),
            sizeBytes: sizeBytes,
            modified: modifiedDate.map { Self.dateFormatter.string(from: $0) } ?? ""
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if handleRemoteDrop(providers) {
            return true
        }
        return handleFileDrop(providers)
    }

    private func handleRemoteDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(RemoteFileDragPayload.typeIdentifier) }) else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: RemoteFileDragPayload.typeIdentifier) { data, _ in
            guard
                let data,
                let payload = try? JSONDecoder().decode(RemoteFileDragPayload.self, from: data),
                let sourceProfileID = UUID(uuidString: payload.profileID)
            else {
                return
            }

            DispatchQueue.main.async {
                guard let sourceProfile = availableProfiles.first(where: { $0.id == sourceProfileID }) else {
                    showAlert(title: "无法传输", message: "没有找到拖拽来源的连接配置。")
                    return
                }

                let destination = URL(fileURLWithPath: expandedLocalPath(pane.pathText), isDirectory: true)
                    .appendingPathComponent(payload.name.isEmpty ? "remote-file" : payload.name)
                    .path
                transferSFTP.download(
                    profile: sourceProfile,
                    remotePath: payload.path,
                    localPath: destination,
                    isDirectory: payload.isDirectory
                )
            }
        }

        return true
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        let collectedPaths = LockedPathCollector()
        let group = DispatchGroup()

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else {
                    url = nil
                }

                guard let url else { return }
                collectedPaths.append(url.path)
            }
        }

        group.notify(queue: .main) {
            copyLocalPaths(collectedPaths.values(), to: expandedLocalPath(pane.pathText))
        }

        return true
    }

    private func chooseAndCopyHere() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            copyLocalPaths(panel.urls.map(\.path), to: expandedLocalPath(pane.pathText))
        }
    }

    private func copySelectedToFolder() {
        guard let selectedEntry = pane.selectedEntry else { return }
        copyToFolder(selectedEntry)
    }

    private func copyToFolder(_ entry: RemoteFileEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let directoryURL = panel.url {
            copyLocalPaths([entry.path], to: directoryURL.path)
        }
    }

    private func copySelectedToPath() {
        guard let selectedEntry = pane.selectedEntry else { return }
        copyToTargetDirectory(selectedEntry)
    }

    private func copyToTargetDirectory(_ entry: RemoteFileEntry) {
        guard let targetDirectory = promptText(
            title: "复制到目标目录",
            message: "输入本地目标目录路径。",
            defaultValue: expandedLocalPath(pane.pathText)
        ) else {
            return
        }
        copyLocalPaths([entry.path], to: targetDirectory)
    }

    private func copyLocalPaths(_ paths: [String], to directory: String) {
        let fileManager = FileManager.default
        let targetDirectory = URL(fileURLWithPath: expandedLocalPath(directory), isDirectory: true)
        var isDirectory = ObjCBool(false)

        guard fileManager.fileExists(atPath: targetDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            showAlert(title: "目标目录不可用", message: targetDirectory.path)
            return
        }

        do {
            for path in paths {
                let sourceURL = URL(fileURLWithPath: path)
                let destinationURL = targetDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destinationURL.path])
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
            statusText = "复制完成"
            loadDirectory(pane.pathText)
        } catch {
            statusText = "复制失败"
            showAlert(title: "复制失败", message: error.localizedDescription)
        }
    }

    private func renameSelected() {
        guard let selectedEntry = pane.selectedEntry else { return }
        rename(selectedEntry)
    }

    private func rename(_ entry: RemoteFileEntry) {
        guard let newName = promptText(title: "重命名", message: "输入新的名称。", defaultValue: entry.name) else { return }
        guard isValidLocalBasename(newName), newName != entry.name else { return }

        let sourceURL = URL(fileURLWithPath: entry.path)
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            pane.selectedEntry = nil
            statusText = "重命名完成"
            loadDirectory(pane.pathText)
        } catch {
            statusText = "重命名失败"
            showAlert(title: "重命名失败", message: error.localizedDescription)
        }
    }

    private func deleteSelected() {
        guard let selectedEntry = pane.selectedEntry else { return }
        delete(selectedEntry)
    }

    private func delete(_ entry: RemoteFileEntry) {
        let message = entry.isDirectory
            ? "确定删除文件夹“\(entry.name)”及其中所有内容吗？"
            : "确定删除文件“\(entry.name)”吗？"
        guard confirmDestructive(title: "删除", message: message) else { return }

        do {
            try FileManager.default.removeItem(atPath: entry.path)
            pane.selectedEntry = nil
            statusText = "删除完成"
            loadDirectory(pane.pathText)
        } catch {
            statusText = "删除失败"
            showAlert(title: "删除失败", message: error.localizedDescription)
        }
    }

    private func createFolder() {
        guard let folderName = promptText(title: "新建文件夹", message: "输入文件夹名称。", defaultValue: "新建文件夹") else { return }
        guard isValidLocalBasename(folderName) else {
            showAlert(title: "名称不可用", message: "名称不能为空，也不能包含 /。")
            return
        }

        let targetURL = URL(fileURLWithPath: expandedLocalPath(pane.pathText), isDirectory: true).appendingPathComponent(folderName)
        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)
            statusText = "新建完成"
            loadDirectory(pane.pathText)
        } catch {
            statusText = "新建失败"
            showAlert(title: "新建文件夹失败", message: error.localizedDescription)
        }
    }

    private func editSelectedPermissions() {
        guard let selectedEntry = pane.selectedEntry else { return }
        editPermissions(selectedEntry)
    }

    private func editPermissions(_ entry: RemoteFileEntry) {
        guard let mode = promptText(title: "修改权限", message: "输入 chmod 权限，例如 755、664。", defaultValue: defaultPermissionMode(for: entry)) else { return }
        guard let value = Int(mode, radix: 8) else {
            showAlert(title: "权限不可用", message: "请输入八进制权限，例如 755。")
            return
        }

        do {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: value)], ofItemAtPath: entry.path)
            statusText = "权限已更新"
            loadDirectory(pane.pathText)
        } catch {
            statusText = "权限修改失败"
            showAlert(title: "权限修改失败", message: error.localizedDescription)
        }
    }

    private func expandedLocalPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? NSHomeDirectory() : trimmed
        return NSString(string: value).expandingTildeInPath
    }

    private func permissionString(mode: Int, isDirectory: Bool, isLink: Bool) -> String {
        var result = isLink ? "l" : (isDirectory ? "d" : "-")
        let masks = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        let letters = ["r", "w", "x", "r", "w", "x", "r", "w", "x"]
        for (index, mask) in masks.enumerated() {
            result += (mode & mask) == mask ? letters[index] : "-"
        }
        return result
    }

    private func isValidLocalBasename(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    private func defaultPermissionMode(for entry: RemoteFileEntry) -> String {
        let permissions = Array(entry.permissions)
        guard permissions.count >= 10 else {
            return entry.isDirectory ? "755" : "644"
        }

        var mode = ""
        for offset in stride(from: 1, through: 7, by: 3) {
            var value = 0
            if permissions[offset] == "r" { value += 4 }
            if permissions[offset + 1] == "w" { value += 2 }
            if permissions[offset + 2] != "-" { value += 1 }
            mode += "\(value)"
        }
        return mode
    }

    private func promptText(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(string: defaultValue)
        textField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        textField.lineBreakMode = .byTruncatingMiddle
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirmDestructive(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

private struct SFTPWorkspacePaneContainer: View {
    @StateObject private var sftp = SFTPManager()

    let title: String
    @Binding var pane: SFTPWorkspacePaneState
    let availableProfiles: [SSHProfile]

    private var selectedProfile: SSHProfile? {
        guard let profileID = pane.profileID else { return nil }
        return availableProfiles.first { $0.id == profileID }
    }

    private var selectedProfileCanConnect: Bool {
        selectedProfile?.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("服务器", selection: profileSelection) {
                    ForEach(availableProfiles) { profile in
                        Text(profile.name)
                            .tag(Optional(profile.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)

                if let selectedProfile {
                    Text(selectedProfile.targetAddress.isEmpty ? "未填写目标主机" : selectedProfile.targetAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("刷新当前面板")
                .disabled(!selectedProfileCanConnect || sftp.status == .running)
            }
            .controlSize(.small)

            if let selectedProfile, selectedProfileCanConnect {
                RemoteFileBrowserPane(
                    profile: selectedProfile,
                    availableProfiles: availableProfiles,
                    selectedEntry: $pane.selectedEntry,
                    remotePathText: $pane.remotePathText,
                    terminalProfileID: nil,
                    automaticallySyncsTerminalDirectory: .constant(false)
                )
                .environmentObject(sftp)
            } else if selectedProfile != nil {
                EmptyStateView(
                    systemImage: "server.rack",
                    title: "未填写目标主机",
                    subtitle: "先点“配置”或在上方选择已有服务器"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                EmptyStateView(
                    systemImage: "server.rack",
                    title: "没有可用配置",
                    subtitle: "先新增终端工作区，或新建一个自定义 SFTP 工作区"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .onAppear(perform: refreshIfNeeded)
        .onChange(of: pane.profileID) { _ in
            pane.selectedEntry = nil
            pane.remotePathText = "."
            sftp.cancel()
            sftp.clear()
            refresh()
        }
    }

    private var profileSelection: Binding<UUID?> {
        Binding(
            get: { pane.profileID },
            set: { pane.profileID = $0 }
        )
    }

    private func refreshIfNeeded() {
        guard sftp.activeProfileID == nil, selectedProfileCanConnect else { return }
        refresh()
    }

    private func refresh() {
        guard let selectedProfile, selectedProfileCanConnect else { return }
        sftp.refreshDirectory(profile: selectedProfile, path: pane.remotePathText)
    }
}

private struct RemoteFileBrowserPane: View {
    @EnvironmentObject private var sftp: SFTPManager
    @EnvironmentObject private var terminal: TerminalManager

    let profile: SSHProfile
    let availableProfiles: [SSHProfile]
    @Binding var selectedEntry: RemoteFileEntry?
    @Binding var remotePathText: String
    let terminalProfileID: UUID?
    @Binding var automaticallySyncsTerminalDirectory: Bool
    @State private var filterText = ""
    @State private var isDropTarget = false
    @State private var sortColumn: RemoteFileSortColumn = .name
    @State private var sortAscending = true

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Color(red: 0.02, green: 0.33, blue: 0.52), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Text(profile.targetHost.isEmpty ? "远程服务器" : profile.targetHost)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    StatusDot(text: sftp.status.label, color: statusColor)
                        .frame(width: 86, alignment: .leading)

                    Spacer()

                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                        TextField("筛选", text: $filterText)
                            .textFieldStyle(.plain)
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: 132)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Menu {
                        Button(action: refresh) {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        Button(action: goParent) {
                            Label("上级文件夹", systemImage: "arrow.up")
                        }
                        Divider()
                        Button(action: chooseAndUpload) {
                            Label("上传到当前目录", systemImage: "arrow.up.doc")
                        }
                        .disabled(sftp.status == .running)
                        Button(action: downloadSelected) {
                            Label("下载选中项", systemImage: "arrow.down.doc")
                        }
                        .disabled(selectedEntry == nil || sftp.status == .running)
                        Button(action: createFolder) {
                            Label("新建文件夹", systemImage: "folder.badge.plus")
                        }
                        .disabled(sftp.status == .running)
                        Divider()
                        Button {
                            if let selectedEntry {
                                copyToTargetDirectory(selectedEntry)
                            }
                        } label: {
                            Label("复制到目标目录", systemImage: "doc.on.doc")
                        }
                        .disabled(!canMutateSelectedEntry)
                        Button {
                            if let selectedEntry {
                                rename(selectedEntry)
                            }
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .disabled(!canMutateSelectedEntry)
                        Button {
                            if let selectedEntry {
                                editPermissions(selectedEntry)
                            }
                        } label: {
                            Label("修改权限", systemImage: "lock.open")
                        }
                        .disabled(!canMutateSelectedEntry)
                        Button(role: .destructive) {
                            if let selectedEntry {
                                delete(selectedEntry)
                            }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .disabled(!canMutateSelectedEntry)
                    } label: {
                        Label("操作", systemImage: "ellipsis.circle")
                    }
                    .disabled(!sftp.canNavigateDirectories)
                }

                HStack(spacing: 8) {
                    Button(action: goParent) {
                        Image(systemName: "chevron.left")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("返回上级")
                    .disabled(isRootPath || !sftp.canNavigateDirectories)

                    Button(action: goParent) {
                        Image(systemName: "chevron.up")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("上级文件夹")
                    .disabled(isRootPath || !sftp.canNavigateDirectories)

                    HStack(spacing: 6) {
                        TextField("远程路径，例如 /home/user", text: $remotePathText)
                            .textFieldStyle(.plain)
                            .font(.caption.weight(.medium))
                            .onSubmit {
                                openPath(remotePathText)
                            }

                        Button {
                            openPath(remotePathText)
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("跳转到输入的远程路径")
                        .disabled(!sftp.canNavigateDirectories)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                    }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(Color(red: 0.965, green: 0.982, blue: 0.988))

            Divider()

            ZStack(alignment: .top) {
                RemoteFileTableView(
                    entries: displayedEntries,
                    profileID: profile.id,
                    selectedEntry: $selectedEntry,
                    sortColumn: $sortColumn,
                    sortAscending: $sortAscending,
                    currentPath: sftp.currentRemotePath,
                    loadingPath: sftp.loadingRemotePath,
                    canNavigate: sftp.canNavigateDirectories,
                    canMutate: sftp.status != .running,
                    onOpen: open,
                    onContextAction: handleContextAction
                )
                .opacity(displayedEntries.isEmpty ? 0 : 1)

                if displayedEntries.isEmpty {
                    EmptyStateView(
                        systemImage: isLoadingDirectory ? "folder.badge.gearshape" : "folder",
                        title: isLoadingDirectory ? "已切换路径，正在同步" : "还没有文件列表",
                        subtitle: isLoadingDirectory ? loadingDirectoryText : (filterText.isEmpty ? "展开文件侧栏后可以刷新，也可以拖拽上传" : "没有匹配的文件")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if isLoadingDirectory && !displayedEntries.isEmpty {
                    loadingBanner
                }
            }

            Divider()
            sftpFooter
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        Label("松开以传输到当前目录", systemImage: "arrow.up.doc.fill")
                            .font(.headline)
                            .padding(18)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.48), lineWidth: 1)
        }
        .onDrop(of: [UTType.fileURL.identifier, RemoteFileDragPayload.typeIdentifier], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .onAppear {
            if remotePathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                remotePathText = sftp.activeProfileID == profile.id ? sftp.currentRemotePath : "."
            }
        }
        .onChange(of: sftp.currentRemotePath) { newPath in
            if sftp.activeProfileID == profile.id {
                remotePathText = newPath
            }
        }
        .onChange(of: terminalDirectory) { newPath in
            guard automaticallySyncsTerminalDirectory, newPath != nil else { return }
            syncToTerminalDirectory(newPath)
        }
    }

    private var statusColor: Color {
        switch sftp.status {
        case .idle:
            return .secondary
        case .running:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private var visibleEntries: [RemoteFileEntry] {
        sftp.activeProfileID == profile.id ? sftp.remoteEntries : []
    }

    private var isLoadingDirectory: Bool {
        sftp.activeProfileID == profile.id && sftp.loadingRemotePath != nil
    }

    private var loadingDirectoryText: String {
        sftp.loadingRemotePath.map { "后台同步 \($0)" } ?? "后台同步远程目录"
    }

    private var filteredEntries: [RemoteFileEntry] {
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return visibleEntries }
        return visibleEntries.filter { entry in
            entry.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var displayedEntries: [RemoteFileEntry] {
        sortedEntries(filteredEntries)
    }

    private var visibleLogText: String {
        sftp.activeProfileID == profile.id ? sftp.logText : ""
    }

    private var terminalDirectory: String? {
        guard let terminalProfileID else { return nil }
        return terminal.currentDirectory(for: terminalProfileID)
    }

    private var isRootPath: Bool {
        let trimmed = remotePathText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "." || trimmed == "/" || trimmed == "~"
    }

    private var canMutateSelectedEntry: Bool {
        guard let selectedEntry else { return false }
        return selectedEntry.name != ".." && sftp.status != .running
    }

    private func refresh() {
        sftp.refreshDirectory(profile: profile, path: remotePathText)
    }

    private func sortedEntries(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        let parentEntries = entries.filter { $0.name == ".." }
        let regularEntries = entries.filter { $0.name != ".." }
        let sorted = regularEntries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }

            let result: ComparisonResult
            switch sortColumn {
            case .name:
                result = lhs.name.localizedStandardCompare(rhs.name)
            case .modified:
                result = lhs.modified.localizedStandardCompare(rhs.modified)
            case .size:
                if lhs.sizeBytes == rhs.sizeBytes {
                    result = lhs.name.localizedStandardCompare(rhs.name)
                } else {
                    result = lhs.sizeBytes < rhs.sizeBytes ? .orderedAscending : .orderedDescending
                }
            case .kind:
                result = lhs.kind.localizedStandardCompare(rhs.kind)
            }

            if result == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
        return parentEntries + sorted
    }

    private func open(_ entry: RemoteFileEntry) {
        guard entry.isDirectory else {
            selectedEntry = entry
            sftp.openFile(profile: profile, entry: entry)
            return
        }

        selectedEntry = nil
        remotePathText = entry.path
        sftp.refreshDirectory(profile: profile, path: entry.path)
    }

    private func handleContextAction(_ action: RemoteFileContextAction, entry: RemoteFileEntry?) {
        switch action {
        case .open:
            if let entry {
                open(entry)
            }
        case .download:
            if let entry {
                download(entry)
            }
        case .uploadHere:
            chooseAndUpload()
        case .copyToDirectory:
            if let entry {
                copyToTargetDirectory(entry)
            }
        case .rename:
            if let entry {
                rename(entry)
            }
        case .delete:
            if let entry {
                delete(entry)
            }
        case .refresh:
            refresh()
        case .newFolder:
            createFolder()
        case .editPermissions:
            if let entry {
                editPermissions(entry)
            }
        }
    }

    private func openPath(_ path: String) {
        selectedEntry = nil
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        remotePathText = trimmed.isEmpty ? "." : trimmed
        sftp.refreshDirectory(profile: profile, path: remotePathText)
    }

    private func goParent() {
        selectedEntry = nil
        let parent = parentRemotePath(remotePathText)
        remotePathText = parent
        sftp.refreshDirectory(profile: profile, path: parent)
    }

    private var loadingBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text(loadingDirectoryText)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func parentRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "/" else { return "." }
        let parts = trimmed.split(separator: "/").dropLast()
        guard !parts.isEmpty else { return trimmed.hasPrefix("/") ? "/" : "." }
        let parent = parts.joined(separator: "/")
        return trimmed.hasPrefix("/") ? "/" + parent : parent
    }

    private func chooseAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let paths = panel.urls.map(\.path)
            sftp.upload(profile: profile, localPaths: paths, remotePath: remotePathText)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if handleRemoteDrop(providers) {
            return true
        }

        return handleFileDrop(providers)
    }

    private func handleRemoteDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(RemoteFileDragPayload.typeIdentifier) }) else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: RemoteFileDragPayload.typeIdentifier) { data, _ in
            guard
                let data,
                let payload = try? JSONDecoder().decode(RemoteFileDragPayload.self, from: data),
                let sourceProfileID = UUID(uuidString: payload.profileID)
            else {
                return
            }

            DispatchQueue.main.async {
                guard let sourceProfile = availableProfiles.first(where: { $0.id == sourceProfileID }) else {
                    showAlert(title: "无法传输", message: "没有找到拖拽来源的连接配置。")
                    return
                }

                sftp.transferRemoteEntry(
                    sourceProfile: sourceProfile,
                    payload: payload,
                    targetProfile: profile,
                    targetDirectory: remotePathText
                )
            }
        }

        return true
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else {
            return false
        }

        let collectedPaths = LockedPathCollector()
        let group = DispatchGroup()

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else {
                    url = nil
                }

                guard let url else { return }
                collectedPaths.append(url.path)
            }
        }

        group.notify(queue: .main) {
            let paths = collectedPaths.values()
            guard !paths.isEmpty else { return }
            sftp.upload(profile: profile, localPaths: paths, remotePath: remotePathText)
        }

        return true
    }

    private func downloadSelected() {
        guard let selectedEntry else { return }
        download(selectedEntry)
    }

    private func download(_ entry: RemoteFileEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let directoryURL = panel.url {
            let destination = directoryURL.appendingPathComponent(entry.name).path
            sftp.download(
                profile: profile,
                remotePath: entry.path,
                localPath: destination,
                isDirectory: entry.isDirectory
            )
        }
    }

    private func copyToTargetDirectory(_ entry: RemoteFileEntry) {
        guard let targetDirectory = promptText(
            title: "复制到目标目录",
            message: "输入远程目标目录路径。",
            defaultValue: remotePathText
        ) else {
            return
        }

        sftp.copyToDirectory(
            profile: profile,
            entry: entry,
            targetDirectory: targetDirectory,
            refreshPath: remotePathText
        )
    }

    private func rename(_ entry: RemoteFileEntry) {
        guard let newName = promptText(
            title: "重命名",
            message: "输入新的名称。",
            defaultValue: entry.name
        ) else {
            return
        }

        guard isValidRemoteBasename(newName) else {
            showAlert(title: "名称不可用", message: "名称不能为空，也不能包含 /。")
            return
        }

        guard newName != entry.name else { return }
        selectedEntry = nil
        sftp.rename(profile: profile, entry: entry, newName: newName, refreshPath: remotePathText)
    }

    private func delete(_ entry: RemoteFileEntry) {
        let message = entry.isDirectory
            ? "确定删除文件夹“\(entry.name)”及其中所有内容吗？"
            : "确定删除文件“\(entry.name)”吗？"
        guard confirmDestructive(title: "删除", message: message) else { return }

        selectedEntry = nil
        sftp.delete(profile: profile, entry: entry, refreshPath: remotePathText)
    }

    private func createFolder() {
        guard let folderName = promptText(
            title: "新建文件夹",
            message: "输入文件夹名称。",
            defaultValue: "新建文件夹"
        ) else {
            return
        }

        guard isValidRemoteBasename(folderName) else {
            showAlert(title: "名称不可用", message: "名称不能为空，也不能包含 /。")
            return
        }

        selectedEntry = nil
        sftp.createDirectory(profile: profile, name: folderName, in: remotePathText)
    }

    private func editPermissions(_ entry: RemoteFileEntry) {
        guard let mode = promptText(
            title: "修改权限",
            message: "输入 chmod 权限，例如 755、664 或 u+x。",
            defaultValue: defaultPermissionMode(for: entry)
        ) else {
            return
        }

        guard !mode.isEmpty else {
            showAlert(title: "权限不可用", message: "请输入 chmod 权限。")
            return
        }

        sftp.changePermissions(profile: profile, entry: entry, mode: mode, refreshPath: remotePathText)
    }

    private func isValidRemoteBasename(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    private func defaultPermissionMode(for entry: RemoteFileEntry) -> String {
        let permissions = Array(entry.permissions)
        guard permissions.count >= 10 else {
            return entry.isDirectory ? "755" : "644"
        }

        var mode = ""
        for offset in stride(from: 1, through: 7, by: 3) {
            var value = 0
            if permissions[offset] == "r" { value += 4 }
            if permissions[offset + 1] == "w" { value += 2 }
            if permissions[offset + 2] != "-" { value += 1 }
            mode += "\(value)"
        }
        return mode
    }

    private func promptText(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(string: defaultValue)
        textField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        textField.lineBreakMode = .byTruncatingMiddle
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func confirmDestructive(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private var sftpFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if terminalProfileID != nil {
                terminalIntegrationButtons
            }

            Button {
                sftp.clear()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("清空 SFTP 状态")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.26))
    }

    private var terminalIntegrationButtons: some View {
        HStack(spacing: 8) {
            Button {
                copySFTPPathToTerminal()
            } label: {
                Label("将 cd 路径复制到终端", systemImage: "terminal")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("将 cd 当前 SFTP 目录复制到终端，回车后进入该目录")

            Button {
                requestAndSyncTerminalDirectory()
            } label: {
                Label("同步到终端文件夹", systemImage: "location")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("同步到终端当前文件夹")

            Button {
                automaticallySyncsTerminalDirectory.toggle()
                if automaticallySyncsTerminalDirectory {
                    requestAndSyncTerminalDirectory()
                }
            } label: {
                Label("自动同步终端文件夹", systemImage: automaticallySyncsTerminalDirectory ? "link.circle.fill" : "link.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(automaticallySyncsTerminalDirectory ? Color.accentColor : .secondary)
            .help(automaticallySyncsTerminalDirectory ? "已开启自动同步终端文件夹" : "开启自动同步终端文件夹")
        }
        .disabled(terminalProfileID.map { !terminal.isRunning($0) } ?? true)
    }

    private var footerText: String {
        if sftp.activeProfileID == profile.id, !sftp.transferProgressText.isEmpty {
            return sftp.transferProgressText == "传输完成" ? "传输完成" : "正在传输：\(sftp.transferProgressText)"
        }

        if sftp.activeProfileID == profile.id {
            switch sftp.status {
            case .running:
                return "后台同步中..."
            case .failed(let message):
                return message
            case .completed, .idle:
                return "\(visibleEntries.count) 个项目"
            }
        }

        return "\(visibleEntries.count) 个项目"
    }

    private func copySFTPPathToTerminal() {
        guard let terminalProfileID else { return }
        terminal.sendText("cd \(remotePathText.shellQuotedForTerminalPaste)", profileID: terminalProfileID)
    }

    private func requestAndSyncTerminalDirectory() {
        guard let terminalProfileID else { return }
        terminal.requestCurrentDirectory(profileID: terminalProfileID) { directory in
            syncToTerminalDirectory(directory)
        }
    }

    private func syncToTerminalDirectory(_ directory: String?) {
        guard let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert(title: "还没有终端目录", message: "还没有捕获到终端当前目录。请先在内置终端里执行一次 cd 命令，或使用支持 OSC 7 的 shell 提示符。")
            return
        }

        selectedEntry = nil
        remotePathText = directory
        sftp.refreshDirectory(profile: profile, path: directory)
    }
}

private final class LockedPathCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        let result = paths
        lock.unlock()
        return result
    }
}

private extension String {
    var shellQuotedForTerminalPaste: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "''" }
        if trimmed.range(of: #"[^A-Za-z0-9_@%+=:,./~-]"#, options: .regularExpression) == nil {
            return trimmed
        }
        return "'" + trimmed.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct StatusDot: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.blue.opacity(0.10))
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.blue)
                }
                .frame(width: 26, height: 26)

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }
}

private struct SettingRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 64, height: 64)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct StatusPill: View {
    let status: TunnelManager.Status

    var body: some View {
        HStack(spacing: 6) {
            if case .connecting = status {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }

            Text(status.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
        .help(helpText)
    }

    private var color: Color {
        switch status {
        case .disconnected:
            return .secondary
        case .connecting:
            return .orange
        case .connected:
            return .green
        case .failed:
            return .red
        }
    }

    private var helpText: String {
        switch status {
        case .failed(let message):
            return message
        default:
            return status.label
        }
    }
}
