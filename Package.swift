// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MuteOnStartup",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "mute-on-startup-agent",
            targets: ["MuteOnStartupAgent"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MuteOnStartupAgent",
            path: "Sources/MuteOnStartupAgent"
        )
    ]
)
