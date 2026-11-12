// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenRecorder",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ScreenRecorder", targets: ["ScreenRecorder"])],
    targets: [
        .target(name: "RecorderCore"),
        .executableTarget(name: "ScreenRecorder", dependencies: ["RecorderCore"]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"]),
        .testTarget(name: "MediaTests", dependencies: ["ScreenRecorder", "RecorderCore"])
    ],
    swiftLanguageModes: [.v5]
)
