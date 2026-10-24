// swift-tools-version:5.10
// Throwaway Phase 0 spike: is CGPath stroke + union good enough as the
// emboldening engine? Kept out of the main package on purpose.
import PackageDescription

let package = Package(
    name: "EmboldenSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "embolden-spike", path: "Sources/EmboldenSpike")
    ]
)
