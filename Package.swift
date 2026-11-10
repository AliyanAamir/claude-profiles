// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeProfiles",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ClaudeProfiles", targets: ["ClaudeProfiles"]),
        .executable(name: "claude-profiles-cli", targets: ["claude-profiles-cli"]),
        .library(name: "ClaudeProfilesCore", targets: ["ClaudeProfilesCore"]),
    ],
    targets: [
        .target(name: "ClaudeProfilesCore"),
        .executableTarget(name: "ClaudeProfiles", dependencies: ["ClaudeProfilesCore"]),
        .executableTarget(name: "claude-profiles-cli", dependencies: ["ClaudeProfilesCore"]),
        .testTarget(name: "ClaudeProfilesCoreTests", dependencies: ["ClaudeProfilesCore"]),
    ],
    swiftLanguageModes: [.v5]
)
