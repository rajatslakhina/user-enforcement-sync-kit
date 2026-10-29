// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "UserEnforcement",
    // Only the platforms CI actually builds: macOS (swift test) and iOS (Simulator build).
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UserEnforcement", targets: ["UserEnforcement"]),
        .library(name: "UserEnforcementUI", targets: ["UserEnforcementUI"]),
    ],
    targets: [
        .target(name: "UserEnforcement"),
        .target(name: "UserEnforcementUI", dependencies: ["UserEnforcement"]),
        .testTarget(name: "UserEnforcementTests", dependencies: ["UserEnforcement"]),
    ],
    swiftLanguageModes: [.v6]
)
