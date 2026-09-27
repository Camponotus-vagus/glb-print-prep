// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GLBPrintPrep",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "GLBPrintPrep", targets: ["GLBPrintPrep"]),
        .library(name: "GLBPrintPrepCore", targets: ["GLBPrintPrepCore"]),
    ],
    targets: [
        // Platform-agnostic logic (engine protocol, detail levels, GLB checks and parsing): unit-tested.
        .target(name: "GLBPrintPrepCore"),
        // SwiftUI + RealityKit app. Bundled into "GLB Print Prep.app" by scripts/build-app.sh.
        .executableTarget(name: "GLBPrintPrep", dependencies: ["GLBPrintPrepCore"]),
        .testTarget(name: "GLBPrintPrepCoreTests", dependencies: ["GLBPrintPrepCore"]),
    ],
    swiftLanguageModes: [.v6]
)
