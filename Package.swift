// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowGroup",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WindowGroup", targets: ["WindowGroup"]),
        .executable(name: "WindowGroupFixture", targets: ["WindowGroupFixture"]),
        .library(name: "WindowGroupCore", targets: ["WindowGroupCore"])
    ],
    targets: [
        .target(name: "WindowGroupCore"),
        .executableTarget(name: "WindowGroup", dependencies: ["WindowGroupCore"]),
        .executableTarget(name: "WindowGroupFixture"),
        .testTarget(name: "WindowGroupCoreTests", dependencies: ["WindowGroupCore"])
    ]
)
