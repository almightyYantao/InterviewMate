// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ResumeScreener",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ResumeScreener", path: "Sources/ResumeScreener",
                          swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
