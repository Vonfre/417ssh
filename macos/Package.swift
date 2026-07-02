// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RemoteJupyterTunnel",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "RemoteJupyterTunnel",
            targets: ["RemoteJupyterTunnel"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "RemoteJupyterTunnel",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        )
    ]
)
