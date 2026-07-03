import SwiftUI

struct AppSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var updateManager: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AppLogo(size: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text("417ssh 设置")
                        .font(.title3.weight(.semibold))
                    Text("版本 \(AppVersion.current)")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("完成") {
                    dismiss()
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.30), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 12) {
                Toggle("启动时自动检查 GitHub 更新", isOn: $updateManager.autoCheckEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    SettingsInfoRow(title: "当前版本", value: AppVersion.current)
                    SettingsInfoRow(title: "最新版本", value: latestVersionText)
                    SettingsInfoRow(title: "更新包", value: updateAssetText)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.panelBackground(colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 1)
                }

                HStack(spacing: 10) {
                    SettingsStatusDot(text: updateManager.status.label, color: statusColor)

                    if case .checking = updateManager.status {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if case .downloading = updateManager.status {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()
                }

                if let release = updateManager.latestRelease,
                   case .updateAvailable = updateManager.status {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(release.name ?? "417ssh \(release.versionString)")
                            .font(.headline)
                        Text(release.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? release.body! : "这个版本没有填写 release notes。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.panelBackground(colorScheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 1)
                    }
                }

                HStack(spacing: 10) {
                    Button("检查更新") {
                        Task {
                            await updateManager.checkForUpdates()
                        }
                    }
                    .disabled(isBusy)

                    Button(downloadButtonTitle) {
                        Task {
                            await updateManager.downloadAndInstallUpdate()
                        }
                    }
                    .disabled(!canDownload)

                    Button("打开 GitHub Releases") {
                        updateManager.openReleasesPage()
                    }
                }
                .controlSize(.regular)
            }

            Text("检查更新会读取 GitHub Releases，并显示当前版本、最新版本和对应的 macOS 更新包。安装新版会自动下载、解压、替换当前 417ssh.app，然后重启应用。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
        .background(AppTheme.sidebarBackground(colorScheme))
        .frame(width: 580, height: 480)
    }

    private var latestVersionText: String {
        if let latestRelease = updateManager.latestRelease {
            return latestRelease.versionString
        }
        return "尚未检查"
    }

    private var updateAssetText: String {
        if let asset = updateManager.latestRelease?.macUpdateAsset {
            return asset.name
        }
        if updateManager.latestRelease != nil {
            return "未找到 macOS 更新包"
        }
        return "尚未检查"
    }

    private var downloadButtonTitle: String {
        if case .updateAvailable = updateManager.status {
            return "下载并安装新版"
        }
        return "下载并安装更新"
    }

    private var isBusy: Bool {
        switch updateManager.status {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    private var canDownload: Bool {
        if case .updateAvailable = updateManager.status {
            return true
        }
        return false
    }

    private var statusColor: Color {
        switch updateManager.status {
        case .idle:
            return .secondary
        case .checking, .downloading, .installing:
            return .orange
        case .upToDate:
            return .green
        case .updateAvailable:
            return .blue
        case .failed:
            return .red
        }
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsStatusDot: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.10), in: Capsule())
    }
}
