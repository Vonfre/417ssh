import AppKit
import SwiftUI

@MainActor
enum AppAssets {
    static let appIconImage: NSImage? = {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return NSImage(contentsOf: iconURL)
        }

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png") {
            return NSImage(contentsOf: iconURL)
        }

        return logoImage
    }()

    static let logoImage: NSImage? = {
        if let bundleURL = Bundle.main.url(forResource: "logo", withExtension: "jpg") {
            return NSImage(contentsOf: bundleURL)
        }

        let localURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("logo.jpg")
        return NSImage(contentsOf: localURL)
    }()
}

struct AppLogo: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let logoImage = AppAssets.appIconImage {
                Image(nsImage: logoImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.green.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(7, size * 0.18), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: max(7, size * 0.18), style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(size > 50 ? 0.12 : 0.06), radius: size > 50 ? 10 : 4, y: size > 50 ? 4 : 1)
    }
}

@MainActor
enum AppIconInstaller {
    static func install() {
        guard let appIconImage = AppAssets.appIconImage else { return }
        NSApplication.shared.applicationIconImage = appIconImage
    }
}
