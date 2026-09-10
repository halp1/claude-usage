// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeUsageCore"),
        .executableTarget(name: "ClaudeUsage", dependencies: ["ClaudeUsageCore"]),
        .testTarget(name: "ClaudeUsageCoreTests", dependencies: ["ClaudeUsageCore"]),
    ]
)
