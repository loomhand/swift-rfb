// swift-tools-version: 6.0

import PackageDescription

// Command Line Tools ship swift-testing outside the default search path and
// `swift test` does not find it there, so the tests build as an executable
// run by scripts/test.sh.
let testingFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

let package = Package(
    name: "swift-rfb",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "RFB", targets: ["RFB"]),
        .library(name: "RFBMetal", targets: ["RFBMetal"]),
        .executable(name: "rfb-view", targets: ["rfb-view"]),
        .executable(name: "rfb-bench", targets: ["rfb-bench"]),
    ],
    targets: [
        .target(name: "RFB"),
        .target(name: "RFBMetal", dependencies: ["RFB"]),
        .executableTarget(name: "rfb-view", dependencies: ["RFB", "RFBMetal"]),
        .executableTarget(name: "rfb-bench", dependencies: ["RFB"]),
        .executableTarget(
            name: "RFBTests",
            dependencies: ["RFB"],
            path: "Tests/RFBTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.unsafeFlags(["-F", testingFrameworks, "-Xfrontend", "-disable-cross-import-overlays"])],
            linkerSettings: [.unsafeFlags(["-F", testingFrameworks, "-Xlinker", "-rpath", "-Xlinker", testingFrameworks])]
        ),
    ]
)
