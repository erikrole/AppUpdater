// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppUpdater",
    platforms: [.macOS("27.0")],
    products: [.library(name: "AppUpdater", targets: ["AppUpdater"])],
    targets: [
        .target(name: "AppUpdater"),
        .executableTarget(name: "UpdaterPreview", dependencies: ["AppUpdater"], path: "Sample"),
        .executableTarget(name: "QuitProbe", dependencies: ["AppUpdater"], path: "QuitProbe"),
        .testTarget(name: "AppUpdaterTests", dependencies: ["AppUpdater", "QuitProbe"]),
    ]
)
