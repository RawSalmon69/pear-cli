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
                "PearControlChannel",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            resources: [.copy("Resources/Runners"), .copy("Resources/Licenses")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The Control Center extension (macOS 26+). build.sh embeds it as
        // Contents/PlugIns/PearControl.appex; nothing else links it.
        .executableTarget(
            name: "PearControl",
            dependencies: ["PearControlChannel"],
            swiftSettings: [.swiftLanguageMode(.v6), .unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension"])]
        ),
        // The Darwin-notification channel both of them speak.
        .target(
            name: "PearControlChannel",
            swiftSettings: [.swiftLanguageMode(.v6), .unsafeFlags(["-application-extension"])]
        ),
        .testTarget(
            name: "PearCompanionTests",
            dependencies: ["PearCompanion", "PearControlChannel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
