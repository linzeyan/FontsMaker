// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FontsMaker",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "FontsMakerKit", targets: ["FontsMakerKit"]),
        .executable(name: "fontsmaker", targets: ["fontsmaker"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0")
    ],
    targets: [
        // The engine ships inside the iOS app, so it may only depend on Apple frameworks.
        .target(
            name: "FontsMakerKit",
            // Folders are copied whole so each upstream license and SOURCE.txt
            // ships next to its data (.process would flatten them and collide).
            resources: [.copy("Resources/OpenCC"), .copy("Resources/Unicode")]
        ),
        .executableTarget(
            name: "fontsmaker",
            dependencies: [
                "FontsMakerKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "FontsMakerKitTests",
            dependencies: ["FontsMakerKit"],
            // Fixtures are read through #filePath rather than bundled, so the
            // generator script and the tests agree on one location.
            exclude: ["Fixtures", "OpenCCTestCases"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
