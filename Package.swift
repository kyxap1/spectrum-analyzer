// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SpectrumAnalyzer",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "SpectrumAnalyzer",
            path: "Sources/SpectrumAnalyzer"
        ),
        .testTarget(
            name: "SpectrumAnalyzerTests",
            dependencies: ["SpectrumAnalyzer"],
            path: "Tests/SpectrumAnalyzerTests"
        ),
    ]
)
