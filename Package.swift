// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RingMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RingMonitor", targets: ["RingMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "RingMonitor",
            path: "Sources/RingMonitor",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
