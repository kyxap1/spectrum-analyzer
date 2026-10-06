// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SpectrumAnalyzer",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "SpectrumAnalyzer",
            path: "Sources/SpectrumAnalyzer",
            resources: [.copy("Advice/prompt.md"), .copy("Advice/starting-positions.md"), .copy("Advice/fetch-domains.txt")]
        ),
        .testTarget(
            name: "SpectrumAnalyzerTests",
            dependencies: ["SpectrumAnalyzer"],
            path: "Tests/SpectrumAnalyzerTests"
        ),
    ]
)
