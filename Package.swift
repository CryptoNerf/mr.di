// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MrDi",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MrDi",
            path: "Sources/MrDi",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
