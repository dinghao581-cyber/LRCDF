// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LRCDF",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "LRCDF", path: "Sources/LRCDF")]
)
