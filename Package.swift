// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MicrophoneControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MicrophoneControl", targets: ["MicrophoneControl"]),
        .executable(name: "MicrophoneControlInstaller", targets: ["MicrophoneControlInstaller"]),
    ],
    targets: [
        .executableTarget(name: "MicrophoneControl"),
        .executableTarget(name: "MicrophoneControlInstaller"),
    ],
    swiftLanguageModes: [.v5]
)
