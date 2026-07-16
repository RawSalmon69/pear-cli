// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PearCompanion",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "PearCompanion",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [.copy("Resources/Runners"), .copy("Resources/Licenses")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PearCompanionTests",
            dependencies: ["PearCompanion"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
