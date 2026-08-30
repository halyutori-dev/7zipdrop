// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SevenZipCompressor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CompressorCore", targets: ["CompressorCore"]),
        .executable(name: "SevenZipCompressorApp", targets: ["SevenZipCompressorApp"]),
    ],
    targets: [
        .target(name: "CompressorCore"),
        .executableTarget(
            name: "SevenZipCompressorApp",
            dependencies: ["CompressorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CompressorCoreTests",
            dependencies: ["CompressorCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
