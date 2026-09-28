// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SteamClipConverter",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "SteamClipConverter",
            path: "Sources/SteamClipConverter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SteamClipConverterTests",
            dependencies: ["SteamClipConverter"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
