// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "HealthBridge", platforms: [.macOS(.v14)],
    products: [.library(name: "BridgeCore", targets: ["BridgeCore"]), .executable(name: "healthbridge", targets: ["HealthBridgeCLI"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(name: "BridgeCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "HealthBridgeCLI", dependencies: ["BridgeCore", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"])
    ], swiftLanguageModes: [.v5]
)
