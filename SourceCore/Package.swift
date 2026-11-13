// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SourceCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "SourceCore", type: .static, targets: ["SourceCore"]),
        .library(name: "SourceRuntime", type: .static, targets: ["SourceRuntime"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.7"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.9.0")
    ],
    targets: [
        .target(name: "SourceCore"),
        .target(
            name: "SourceRuntime",
            dependencies: [
                "SourceCore",
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "CryptoSwift", package: "CryptoSwift")
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "SourceCoreTests", dependencies: ["SourceCore"]),
        .testTarget(name: "SourceRuntimeTests", dependencies: ["SourceRuntime", "SourceCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
