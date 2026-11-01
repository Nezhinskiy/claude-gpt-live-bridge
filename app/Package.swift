// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LiveBridge",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "BridgeCore", targets: ["BridgeCore"]),
    .executable(name: "LiveBridge", targets: ["LiveBridge"]),
  ],
  targets: [
    .target(name: "BridgeCore"),
    .executableTarget(name: "LiveBridge", dependencies: ["BridgeCore"]),
    .testTarget(
      name: "BridgeCoreTests",
      dependencies: ["BridgeCore"],
      resources: [.copy("Fixtures")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
