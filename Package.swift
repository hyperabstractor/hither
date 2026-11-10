// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Hither",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Shared", targets: ["Shared"]),   // also used by the iPhone app in iOS/
    ],
    targets: [
        .target(name: "Shared"),
        .target(name: "VirtualDisplay"),   // private CoreGraphics classes, declared (Adaptive Desktop's exact size)
        .executableTarget(name: "hither-host", dependencies: ["Shared", "VirtualDisplay"]),
        .executableTarget(name: "hither", dependencies: ["Shared"]),
        // An executable keeps regression checks runnable with Command Line Tools, without an Xcode test SDK.
        .executableTarget(name: "hither-tests", dependencies: ["Shared"], path: "Tests/Regression"),
    ]
)
