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
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .executableTarget(
            name: "NetMounter",
            dependencies: [],
            path: "Sources/NetMounter",
            resources: [
                .process("Resources")
            ]),
        .testTarget(
            name: "NetMounterTests",
            dependencies: ["NetMounter"],
            path: "Tests/NetMounterTests"),
    ]
)
