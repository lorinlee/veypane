// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Veypane",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VeypaneCore",
            targets: ["VeypaneCore"]
        ),
        .executable(
            name: "VeypaneApp",
            targets: ["VeypaneApp"]
        ),
        .executable(
            name: "veypanectl",
            targets: ["veypanectl"]
        )
    ],
    targets: [
        .target(
            name: "VeypaneCore",
            path: "Sources/VeypaneCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "VeypaneApp",
            dependencies: ["VeypaneCore"],
            path: "Sources/VeypaneApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("WebKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("AppIntents"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .executableTarget(
            name: "veypanectl",
            dependencies: ["VeypaneCore"],
            path: "Sources/veypanectl"
        ),
        .testTarget(
            name: "VeypaneCoreTests",
            dependencies: ["VeypaneCore", "VeypaneApp"],
            path: "Tests/VeypaneCoreTests"
        )
    ]
)
