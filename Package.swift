// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "UsageBar",
            path: "Sources/UsageBar",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "UsageBarTests",
            dependencies: ["UsageBar"]
        )
    ]
)
