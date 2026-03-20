// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkyPaste",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SkyPaste", targets: ["SkyPaste"])
    ],
    targets: [
        .executableTarget(
            name: "SkyPaste",
            path: "Sources",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
