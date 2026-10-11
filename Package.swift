// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GCap",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "GCap", path: "Sources/GCap", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
