// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorkbenchCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WorkbenchCore", targets: ["WorkbenchCore"])
    ],
    targets: [
        .target(name: "WorkbenchCore", resources: [.copy("Fixture")]),
        .testTarget(name: "WorkbenchCoreTests", dependencies: ["WorkbenchCore"]),
    ]
)
