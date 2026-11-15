// swift-tools-version:6.2
import PackageDescription

// macOS 26 and later only (the user's decision, 2026-11-15): the interface is built on Liquid Glass.
let package = Package(
    name: "LRCDF",
    platforms: [.macOS(.v26)],
    targets: [.executableTarget(name: "LRCDF", path: "Sources/LRCDF", swiftSettings: [.swiftLanguageMode(.v5)])]
)
