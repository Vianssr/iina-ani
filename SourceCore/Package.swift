// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SourceCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "SourceCore", type: .static, targets: ["SourceCore"])],
    targets: [
        .target(name: "SourceCore"),
        .testTarget(name: "SourceCoreTests", dependencies: ["SourceCore"])
    ]
)
