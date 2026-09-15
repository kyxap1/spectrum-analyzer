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
            path: "Tests/SpectrumAnalyzerTests",
            // Command Line Tools ships swift-testing outside the SDK proper;
            // without this search path `swift test` fails with "no such
            // module 'Testing'" (no full Xcode installed on this host).
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                              "-Xlinker", "-rpath",
                              "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ]
        ),
    ]
)
