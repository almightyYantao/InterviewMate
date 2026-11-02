// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ResumeScreener",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(name: "ResumeScreener", dependencies: ["WhisperKit"], path: "Sources/ResumeScreener",
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
