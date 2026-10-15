// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AntiSleep",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AntiSleep", targets: ["AntiSleep"]),
               .executable(name: "anti-sleep-pmset", targets: ["AntiSleepHelper"])],
    targets: [
        .target(name: "AntiSleepCore"),
        .executableTarget(name: "AntiSleep", dependencies: ["AntiSleepCore"]),
        .executableTarget(name: "AntiSleepHelper"),
        .executableTarget(name: "AntiSleepChecks", dependencies: ["AntiSleepCore"], path: "Tests/AntiSleepTests")
    ]
)
