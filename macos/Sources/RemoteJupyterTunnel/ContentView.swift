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
    @State private var isShowingSettings = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 330)
        } detail: {
            if let profile = store.selectedProfile {
                switch profile.workspaceKind {
                case .jupyter:
                    JupyterWorkspaceView(
                        profileBox: store.binding(for: profile),
                        reloadToken: $reloadToken,
                        onEdit: {
                            editingProfileID = profile.id
                        }
                    )
                case .terminal:
                    TerminalWorkspaceView(
                        profileBox: store.binding(for: profile),
                        onEdit: {
                            editingProfileID = profile.id
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
                    profileBox: store.binding(for: profile),
                    onDone: {
                        self.editingProfileID = nil
                    }
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
                    editingProfileID = nil
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
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 14) {
                    ProfileSectionView(
                        title: WorkspaceKind.jupyter.sidebarTitle,
                        count: store.profiles(for: .jupyter).count,
                        addHelp: "新增 Jupyter 工作区",
                        onAdd: {
                            store.addProfile(kind: .jupyter)
                            editingProfileID = store.selectedProfileID
                        }
                    ) {
                        profileRows(for: .jupyter)
                    }

                    ProfileSectionView(
                        title: WorkspaceKind.terminal.sidebarTitle,
                        count: store.profiles(for: .terminal).count,
                        addHelp: "新增终端工作区",
                        onAdd: {
                            store.addProfile(kind: .terminal)
                            editingProfileID = store.selectedProfileID
                        }
                    ) {
                        profileRows(for: .terminal)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            Divider()
                .opacity(0.45)

            HStack(spacing: 8) {
                Button {
                    store.addProfile(kind: .jupyter)
                    editingProfileID = store.selectedProfileID
                } label: {
                    Label("Jupyter", systemImage: "plus.rectangle.on.rectangle")
                }
                .help("新增 Jupyter 工作区")

                Button {
                    store.addProfile(kind: .terminal)
                    editingProfileID = store.selectedProfileID
                } label: {
                    Label("终端", systemImage: "plus.viewfinder")
                }
                .help("新增终端工作区")

                Button {
                    store.duplicateSelectedProfile()
                    editingProfileID = store.selectedProfileID
                } label: {
                    Label("复制", systemImage: "plus.square.on.square")
                }
                .help("复制当前配置")

                Button(role: .destructive) {
                    store.deleteSelectedProfile()
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(store.profiles.isEmpty)
                .help("删除当前配置")

                Button {
                    isShowingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .help("打开设置")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(sidebarFooterBackground)
        }
        .background(sidebarBackground)
    }

    private var sidebarBackground: Color {
        if colorScheme == .dark {
            return Color(nsColor: .windowBackgroundColor)
        }

        return Color(red: 0.965, green: 0.982, blue: 0.972)
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
            Text(kind == .jupyter ? "还没有 Jupyter 配置" : "还没有终端配置")
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
                        editingProfileID = profile.id
                    }
                )
            }
        }
    }

    private func isProfileActive(_ profile: SSHProfile) -> Bool {
        switch profile.workspaceKind {
        case .jupyter:
            return tunnel.activeProfileID == profile.id && tunnel.status.isRunning
        case .terminal:
            return terminal.activeProfileID == profile.id && terminal.status.isRunning
        }
    }
}

private struct ProfileSectionView<Content: View>: View {
    let title: String
    let count: Int
    let addHelp: String
    let onAdd: () -> Void
    @ViewBuilder var content: Content

    init(
        title: String,
        count: Int,
        addHelp: String,
        onAdd: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.count = count
        self.addHelp = addHelp
        self.onAdd = onAdd
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

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(addHelp)
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
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Color.green.opacity(0.16) : Color.secondary.opacity(0.10))

                Image(systemName: isActive ? "point.3.connected.trianglepath.dotted" : profile.workspaceKind.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? .green : .secondary)
            }
            .frame(width: 28, height: 28)

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
        case .jupyter:
            return "\(profile.localPort) -> \(profile.remoteHost):\(profile.remotePort)"
        case .terminal:
            return profile.targetAddress.isEmpty ? "未填写目标主机" : profile.targetAddress
        }
    }
}

private struct JupyterWorkspaceView: View {
    @EnvironmentObject private var tunnel: TunnelManager

    let profileBox: BindingBox<SSHProfile>
    @Binding var reloadToken: Int
    let onEdit: () -> Void

    @State private var selectedTab = JupyterTab.browser

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
                    ForEach(JupyterTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)

                Spacer(minLength: 0)

                StatusDot(
                    text: isCurrentProfileActive ? "Jupyter 已连接" : "Jupyter 未连接",
                    color: isCurrentProfileActive ? .green : .secondary
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
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.48), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.14), value: selectedTab)
    }

    private var browserPane: some View {
        ZStack {
            JupyterWebView(url: currentProfile.localURL, reloadToken: reloadToken)

            if !isCurrentProfileActive {
                EmptyStateView(
                    systemImage: "network.slash",
                    title: "未连接",
                    subtitle: "连接成功后，这里会显示 Jupyter Lab"
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
    let profileBox: BindingBox<SSHProfile>
    let onDone: () -> Void

    private var profile: Binding<SSHProfile> {
        Binding(
            get: { profileBox.get() },
            set: { profileBox.set($0) }
        )
    }

    private var currentProfile: SSHProfile {
        profileBox.get()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppLogo(size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("修改配置")
                        .font(.title3.weight(.semibold))
                    Text(currentProfile.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("完成", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    Picker("工作区", selection: profile.workspaceKind) {
                        ForEach(WorkspaceKind.allCases) { kind in
                            Label(kind.title, systemImage: kind.systemImage)
                                .tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                }

                labeledTextField("名称", text: profile.name)
                labeledSecureField("SSH 密码", text: profile.sshPassword)

                if currentProfile.workspaceKind == .jupyter {
                    SettingRow("Jupyter 地址") {
                        Text(currentProfile.localURLString)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    labeledTextField("页面路径", text: profile.jupyterPath)
                }
            }

            if currentProfile.workspaceKind == .jupyter {
                SettingsSection(title: "Jupyter 本地转发", systemImage: "arrow.left.arrow.right") {
                    labeledIntField("本地端口", value: profile.localPort)
                    labeledTextField("远程主机", text: profile.remoteHost)
                    labeledIntField("远程端口", value: profile.remotePort)
                    Toggle("启用 -g", isOn: profile.allowRemoteLocalPortAccess)
                }
            }

            SettingsSection(title: "跳板机", systemImage: "point.3.connected.trianglepath.dotted") {
                labeledTextField("用户名", text: profile.jumpUser)
                labeledTextField("主机", text: profile.jumpHost)
                labeledIntField("端口", value: profile.jumpPort)
            }

            SettingsSection(title: "目标主机", systemImage: "server.rack") {
                labeledTextField("用户名", text: profile.targetUser)
                labeledTextField("主机", text: profile.targetHost)
                labeledIntField("SSH 端口", value: profile.targetPort)
                labeledTextField("密钥文件", text: profile.identityFile, prompt: "~/.ssh/id_ed25519")
                Toggle("启用压缩 (-C)", isOn: profile.compressionEnabled)
                Toggle("详细日志 (-v)", isOn: profile.verboseLogging)
            }

            SettingsSection(title: "连接稳定性", systemImage: "antenna.radiowaves.left.and.right") {
                Toggle("保持长连接", isOn: profile.keepAliveEnabled)
                labeledIntField("保活间隔", value: profile.keepAliveInterval)
                labeledIntField("容错次数", value: profile.keepAliveCountMax)
                Toggle("使用本机 ~/.ssh/config", isOn: profile.useSSHConfig)
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
}

private enum JupyterTab: String, CaseIterable, Identifiable {
    case browser
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser:
            return "Jupyter"
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

private struct TerminalWorkspaceView: View {
    @EnvironmentObject private var terminal: TerminalManager
    @EnvironmentObject private var sftp: SFTPManager

    let profileBox: BindingBox<SSHProfile>
    let onEdit: () -> Void

    @State private var selectedEntry: RemoteFileEntry?
    @State private var remotePathText = "."

    private var currentProfile: SSHProfile {
        profileBox.get()
    }

    private var isCurrentProfileTerminal: Bool {
        terminal.activeProfileID == currentProfile.id && terminal.status.isRunning
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HSplitView {
                terminalPane
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                RemoteFileBrowserPane(
                    profile: currentProfile,
                    selectedEntry: $selectedEntry,
                    remotePathText: $remotePathText
                )
                .frame(minWidth: 360, idealWidth: 520, maxWidth: 780, maxHeight: .infinity)
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            remotePathText = sftp.activeProfileID == currentProfile.id ? sftp.currentRemotePath : "."
        }
        .onChange(of: terminal.status) { newStatus in
            guard
                newStatus == .connected,
                terminal.activeProfileID == currentProfile.id
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

        Button(action: refreshFiles) {
            Label("刷新文件", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(sftp.status == .running || currentProfile.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button {
            NativeTerminalLauncher.open(profile: currentProfile)
        } label: {
            Label("原生终端", systemImage: "macwindow")
        }
        .buttonStyle(.bordered)
        .disabled(currentProfile.targetHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button {
            if isCurrentProfileTerminal {
                terminal.disconnect()
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
                    terminal.clear()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .help("清空终端输出")

                Button {
                    terminal.sendControlC()
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
                        systemImage: terminal.activeProfileID == nil ? "terminal" : "rectangle.2.swap",
                        title: terminal.activeProfileID == nil ? "终端未连接" : "其他终端正在运行",
                        subtitle: terminal.activeProfileID == nil ? "点击“连接终端”后，这里就是完整 PTY 终端" : "连接当前终端会先断开旧终端"
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
        if terminal.activeProfileID == currentProfile.id {
            return terminal.terminalTitle
        }

        return "SSH 终端"
    }

    private var terminalStatusColor: Color {
        if terminal.activeProfileID != nil, terminal.activeProfileID != currentProfile.id {
            return .orange
        }

        switch terminal.status {
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
        if terminal.activeProfileID != nil, terminal.activeProfileID != currentProfile.id {
            return "其他终端运行中"
        }

        return terminal.status.label
    }

    private func refreshFiles() {
        sftp.refreshDirectory(profile: currentProfile, path: remotePathText)
    }
}

private struct RemoteFileBrowserPane: View {
    @EnvironmentObject private var sftp: SFTPManager

    let profile: SSHProfile
    @Binding var selectedEntry: RemoteFileEntry?
    @Binding var remotePathText: String
    @State private var filterText = ""
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color(red: 0.02, green: 0.33, blue: 0.52), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(profile.targetHost.isEmpty ? "远程服务器" : profile.targetHost)
                        .font(.headline)
                        .lineLimit(1)

                    StatusDot(text: sftp.status.label, color: statusColor)
                        .frame(width: 96, alignment: .leading)

                    Spacer()

                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                        TextField("筛选", text: $filterText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(width: 150)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

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
                    } label: {
                        Label("操作", systemImage: "ellipsis.circle")
                    }
                    .disabled(!sftp.canNavigateDirectories)
                }

                HStack(spacing: 8) {
                    Button(action: goParent) {
                        Image(systemName: "chevron.left")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("返回上级")
                    .disabled(isRootPath || !sftp.canNavigateDirectories)

                    Button(action: goParent) {
                        Image(systemName: "chevron.up")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("上级文件夹")
                    .disabled(isRootPath || !sftp.canNavigateDirectories)

                    HStack(spacing: 6) {
                        TextField("远程路径，例如 /home/zhanghuan", text: $remotePathText)
                            .textFieldStyle(.plain)
                            .font(.callout.weight(.medium))
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                    }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(Color(red: 0.965, green: 0.982, blue: 0.988))

            Divider()

            ZStack(alignment: .top) {
                RemoteFileTableView(
                    entries: filteredEntries,
                    selectedEntry: $selectedEntry,
                    currentPath: sftp.currentRemotePath,
                    loadingPath: sftp.loadingRemotePath,
                    onOpen: open
                )
                .opacity(filteredEntries.isEmpty ? 0 : 1)

                if filteredEntries.isEmpty {
                    EmptyStateView(
                        systemImage: isLoadingDirectory ? "folder.badge.gearshape" : "folder",
                        title: isLoadingDirectory ? "正在打开文件夹" : "还没有文件列表",
                        subtitle: isLoadingDirectory ? loadingDirectoryText : (filterText.isEmpty ? "连接终端后会自动刷新，也可以点击刷新按钮" : "没有匹配的文件")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if isLoadingDirectory && !filteredEntries.isEmpty {
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
                        Label("松开以上传到当前目录", systemImage: "arrow.up.doc.fill")
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
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
            handleFileDrop(providers)
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
        sftp.loadingRemotePath.map { "正在读取 \($0)" } ?? "正在读取远程目录"
    }

    private var filteredEntries: [RemoteFileEntry] {
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return visibleEntries }
        return visibleEntries.filter { entry in
            entry.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var visibleLogText: String {
        sftp.activeProfileID == profile.id ? sftp.logText : ""
    }

    private var isRootPath: Bool {
        let trimmed = remotePathText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "." || trimmed == "/" || trimmed == "~"
    }

    private func refresh() {
        sftp.refreshDirectory(profile: profile, path: remotePathText)
    }

    private func open(_ entry: RemoteFileEntry) {
        guard entry.isDirectory else {
            selectedEntry = entry
            return
        }

        selectedEntry = nil
        remotePathText = entry.path
        sftp.refreshDirectory(profile: profile, path: entry.path)
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
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sftp.upload(profile: profile, localPath: url.path, remotePath: remotePathText)
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let itemURL = item as? URL {
                url = itemURL
            } else {
                url = nil
            }

            guard let url else { return }
            DispatchQueue.main.async {
                sftp.upload(profile: profile, localPath: url.path, remotePath: remotePathText)
            }
        }

        return true
    }

    private func downloadSelected() {
        guard let selectedEntry else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let directoryURL = panel.url {
            let destination = directoryURL.appendingPathComponent(selectedEntry.name).path
            sftp.download(
                profile: profile,
                remotePath: selectedEntry.path,
                localPath: destination,
                isDirectory: selectedEntry.isDirectory
            )
        }
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

    private var footerText: String {
        if sftp.activeProfileID == profile.id, !sftp.transferProgressText.isEmpty {
            return sftp.transferProgressText == "传输完成" ? "传输完成" : "正在传输：\(sftp.transferProgressText)"
        }

        if sftp.activeProfileID == profile.id {
            switch sftp.status {
            case .running:
                return "正在处理..."
            case .failed(let message):
                return message
            case .completed, .idle:
                return "\(visibleEntries.count) 个项目"
            }
        }

        return "\(visibleEntries.count) 个项目"
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
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)

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
            AppLogo(size: 72)
                .opacity(0.88)

            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.secondary)

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
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

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
