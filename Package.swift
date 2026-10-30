// swift-tools-version: 6.0

import PackageDescription

let swift6: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "CCRelay",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "CompanionPlatform", targets: ["CompanionPlatform"]),
        .library(name: "CompanionUI", targets: ["CompanionUI"]),
        .executable(name: "CCRelay", targets: ["CCRelay"]),
        .executable(name: "FakeClaude", targets: ["FakeClaude"]),
        .executable(name: "CompanionNativeWorker", targets: ["CompanionNativeWorker"]),
    ],
    targets: [
        .target(
            name: "CompanionCore",
            swiftSettings: swift6
        ),
        .target(
            name: "CompanionPlatform",
            dependencies: ["CompanionCore"],
            swiftSettings: swift6
        ),
        .target(
            name: "CompanionUI",
            dependencies: ["CompanionCore"],
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "CCRelay",
            dependencies: ["CompanionCore", "CompanionPlatform", "CompanionUI"],
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "FakeClaude",
            swiftSettings: swift6
        ),
        .executableTarget(
            name: "CompanionNativeWorker",
            dependencies: ["CompanionCore"],
            swiftSettings: swift6
        ),
        .testTarget(
            name: "CompanionCoreTests",
            dependencies: ["CompanionCore"],
            swiftSettings: swift6
        ),
        .testTarget(
            name: "CompanionPlatformTests",
            dependencies: ["CompanionPlatform"],
            swiftSettings: swift6
        ),
        .testTarget(
            name: "CompanionUITests",
            dependencies: ["CompanionUI", "CompanionCore"],
            swiftSettings: swift6
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["CCRelay", "CompanionCore", "CompanionPlatform", "CompanionUI"],
            swiftSettings: swift6
        ),
    ]
)
