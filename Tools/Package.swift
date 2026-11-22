// swift-tools-version:6.0
// Development tools for CapsuleerKit. A separate package, so apps that depend on CapsuleerKit
// never resolve swift-openapi-generator. Used by Scripts/update-esi-spec.sh:
//   swift run --package-path Tools --scratch-path Tools/.build swift-openapi-generator generate …
import PackageDescription

let package = Package(
    name: "CapsuleerKitTools",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.4"),
    ],
    targets: [
        // SwiftPM needs at least one target. The generator is an executable product of the
        // dependency and is run with `swift run swift-openapi-generator`.
        .target(
            name: "CapsuleerKitTools",
            path: "Sources/CapsuleerKitTools"),
    ]
)
