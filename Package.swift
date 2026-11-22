// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CapsuleerKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CapsuleerCore", targets: ["CapsuleerCore"]),
        .library(name: "SDEKit", targets: ["SDEKit"]),
        .library(name: "ESIKit", targets: ["ESIKit"]),
        .library(name: "CapsuleerKitTesting", targets: ["CapsuleerKitTesting"]),
        .executable(name: "capsuleer", targets: ["capsuleer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.3.0"),
    ],
    targets: [
        .target(name: "CapsuleerCore"),
        .target(name: "SDEKit", dependencies: ["CapsuleerCore"]),
        .target(
            name: "ESIKit",
            dependencies: [
                "CapsuleerCore",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            exclude: ["Generated/README.md"]),
        .target(name: "CapsuleerKitTesting", dependencies: ["CapsuleerCore"]),
        .executableTarget(
            name: "capsuleer",
            dependencies: [
                "CapsuleerCore", "SDEKit", "ESIKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "CapsuleerCoreTests", dependencies: ["CapsuleerCore", "CapsuleerKitTesting"]),
        .testTarget(
            name: "SDEKitTests",
            dependencies: ["SDEKit", "CapsuleerCore", "CapsuleerKitTesting"],
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "ESIKitTests",
            dependencies: ["ESIKit", "CapsuleerCore", "CapsuleerKitTesting"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "LiveTests", dependencies: ["SDEKit", "ESIKit", "CapsuleerCore"]),
    ],
    swiftLanguageModes: [.v6]
)
