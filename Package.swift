// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorktreesUI",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WorktreeKit"),
        .executableTarget(name: "WorktreesUI", dependencies: ["WorktreeKit"]),
        // Shipped inside Worktrees.app and run by the daily LaunchAgent, so the
        // scheduled cleanup applies exactly the policy the app's Settings show.
        .executableTarget(name: "worktrees-cleanup", dependencies: ["WorktreeKit"]),
        .testTarget(name: "WorktreeKitTests", dependencies: ["WorktreeKit"]),
        .testTarget(name: "WorktreesUITests", dependencies: ["WorktreesUI", "WorktreeKit"]),
    ]
)
