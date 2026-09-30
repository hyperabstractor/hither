// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Hither",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Shared"),
        .executableTarget(name: "hither-host", dependencies: ["Shared"]),
        .executableTarget(name: "hither", dependencies: ["Shared"]),
    ]
)
