// swift-tools-version:6.2
import PackageDescription

// macOS 14 and later (the user's decision, 2026-11-17: one package for all). On macOS 26 the interface is Liquid Glass;
// on 14 and 15 the glass is replaced by plain dark panels (Design.swift, glass()), everything else is the same.
// 14 is also the floor of the bundled Python libraries (torch, numpy, scipy, onnxruntime wheels are macosx_14_0).
let package = Package(
    name: "LRCDF",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "LRCDF", path: "Sources/LRCDF", swiftSettings: [.swiftLanguageMode(.v5)])]
)
