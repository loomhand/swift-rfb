// swift-tools-version: 6.0

import PackageDescription

// pump-proxy puts a client-side request pump between an RFB client and server,
// to compare it with swift-rfb's own request pacing.
let package = Package(
    name: "PumpProxy",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "pump-proxy", swiftSettings: [.swiftLanguageMode(.v5)])]
)
