// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MockGameClock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "mock-game-clock", targets: ["MockGameClockCLI"])],
    targets: [
        .target(name: "ClockVideo", path: "MockGameClock", exclude: ["Assets.xcassets", "ContentView.swift", "MockGameClockApp.swift"], sources: ["ClockVideo.swift"]),
        .executableTarget(name: "MockGameClockCLI", dependencies: ["ClockVideo"], path: "CLI")
    ]
)
