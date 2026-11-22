// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CapsuleerKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CapsuleerCore", targets: ["CapsuleerCore"]),
        .library(name: "SDEKit", targets: ["SDEKit"]),
        .library(name: "CapsuleerKitTesting", targets: ["CapsuleerKitTesting"]),
        .executable(name: "capsuleer", targets: ["capsuleer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "CapsuleerCore"),
        .target(name: "SDEKit", dependencies: ["CapsuleerCore"]),
        .target(name: "CapsuleerKitTesting", dependencies: ["CapsuleerCore"]),
        .executableTarget(
            name: "capsuleer",
            dependencies: [
                "CapsuleerCore", "SDEKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "CapsuleerCoreTests", dependencies: ["CapsuleerCore", "CapsuleerKitTesting"]),
        .testTarget(
            name: "SDEKitTests",
            dependencies: ["SDEKit", "CapsuleerCore", "CapsuleerKitTesting"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "LiveTests", dependencies: ["SDEKit", "CapsuleerCore"]),
    ],
    swiftLanguageModes: [.v6]
)
