// swift-tools-version: 6.0

import PackageDescription

// Baseline viewer on RoyalVNCKit 1.1.0 (pinned by revision), kept
// out of the main package so swift-rfb has no third-party dependency.
let package = Package(
    name: "RoyalVNCView",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/royalapplications/royalvnc.git", revision: "92d4427c73817d8f849bb289ff190aa4b40c44ea"),
    ],
    targets: [
        .executableTarget(
            name: "royalvnc-view",
            dependencies: [.product(name: "RoyalVNCKit", package: "royalvnc")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
