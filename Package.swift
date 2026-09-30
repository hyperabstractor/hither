// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Hither",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Shared"),
        .executableTarget(name: "hither-host", dependencies: ["Shared"]),
        .executableTarget(name: "hither", dependencies: ["Shared"]),
        // An executable keeps regression checks runnable with Command Line Tools, without an Xcode test SDK.
        .executableTarget(name: "hither-tests", dependencies: ["Shared"], path: "Tests/Regression"),
    ]
)
