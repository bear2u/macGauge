// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacGauge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacGauge", targets: ["MacGauge"])],
    targets: [
        .target(name: "MacGaugeCore"),
        .executableTarget(name: "MacGauge", dependencies: ["MacGaugeCore"]),
        .testTarget(name: "MacGaugeCoreTests", dependencies: ["MacGaugeCore"])
    ],
    swiftLanguageModes: [.v5]
)
