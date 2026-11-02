// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "HomeKitLocal",
    platforms: [.macOS(.v13)],
    products: [.library(name: "HomeKitMCPCore", targets: ["HomeKitMCPCore"]),
               .executable(name: "homekit-mcp-fixture", targets: ["HomeKitMCPFixture"])],
    targets: [
        .target(name: "HomeKitMCPCore", path: "HomeKitSync",
                exclude: ["MCPApp.swift", "HomeKitManager.swift", "Info.plist", "HomeKitSync.entitlements"],
                sources: ["MCPServer.swift", "HTTPMCPServer.swift"]),
        .executableTarget(name: "HomeKitMCPFixture", dependencies: ["HomeKitMCPCore"], path: "Tests/Fixtures"),
        .testTarget(name: "HomeKitMCPCoreTests", dependencies: ["HomeKitMCPCore"], path: "Tests/HomeKitMCPCoreTests")
    ]
)
