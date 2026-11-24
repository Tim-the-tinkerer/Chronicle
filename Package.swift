// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Chronicle",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Chronicle", targets: ["Chronicle"]),
    ],
    targets: [
        .executableTarget(
            name: "Chronicle",
            path: "Sources/Chronicle",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("CoreServices"),
            ]
        ),
    ]
)
