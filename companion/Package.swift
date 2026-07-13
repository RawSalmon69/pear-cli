// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PearCompanion",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "PearCompanion",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "PearCompanionTests",
            dependencies: ["PearCompanion"]
        ),
    ]
)
