// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorktreesUI",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WorktreeKit"),
        .executableTarget(name: "WorktreesUI", dependencies: ["WorktreeKit"]),
        .testTarget(name: "WorktreeKitTests", dependencies: ["WorktreeKit"]),
        .testTarget(name: "WorktreesUITests", dependencies: ["WorktreesUI", "WorktreeKit"]),
    ]
)
