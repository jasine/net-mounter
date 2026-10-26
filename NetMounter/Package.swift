// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NetMounter",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "NetMounter",
            targets: ["NetMounter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // Official static SDK: pin the artifact and checksum without downloading unused variants.
        .binaryTarget(
            name: "Sentry",
            url: "https://github.com/getsentry/sentry-cocoa/releases/download/9.31.0/Sentry.xcframework.zip",
            checksum: "86dde13e6145ea3049ee2eb0b07ccb66e137a4d3af0d0dfe0b9d895f80b43237"
        ),
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .executableTarget(
            name: "NetMounter",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "Sentry",
            ],
            path: "Sources/NetMounter",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(
            name: "NetMounterTests",
            dependencies: ["NetMounter"],
            path: "Tests/NetMounterTests"),
    ]
)
