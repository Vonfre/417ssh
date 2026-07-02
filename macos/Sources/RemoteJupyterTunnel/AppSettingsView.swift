import SwiftUI

struct AppSettingsView: View {
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
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Toggle("启动时自动检查 GitHub 更新", isOn: $updateManager.autoCheckEnabled)

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
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                HStack(spacing: 10) {
                    Button("检查更新") {
                        Task {
                            await updateManager.checkForUpdates()
                        }
                    }
                    .disabled(isBusy)

                    Button("下载并打开安装包") {
                        Task {
                            await updateManager.downloadAndOpenInstaller()
                        }
                    }
                    .disabled(!canDownload)

                    Button("打开 GitHub Releases") {
                        updateManager.openReleasesPage()
                    }
                }
            }

            Text("macOS 版会下载 GitHub Release 中的 .dmg 并打开它；如果要做到完全静默替换运行中的应用，后续需要接入签名、notarization 和 Sparkle。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }

    private var isBusy: Bool {
        switch updateManager.status {
        case .checking, .downloading:
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
        case .checking, .downloading:
            return .orange
        case .upToDate, .downloaded:
            return .green
        case .updateAvailable:
            return .blue
        case .failed:
            return .red
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
