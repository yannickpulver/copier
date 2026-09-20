// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CopierCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CopierCore", targets: ["CopierCore"])
    ],
    targets: [
        .target(
            name: "CopierCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CopierCoreTests",
            dependencies: ["CopierCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
