// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyReadKBridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "my-read-k-bridge", targets: ["MyReadKBridge"])
    ],
    targets: [
        .executableTarget(name: "MyReadKBridge"),
        .testTarget(name: "MyReadKBridgeTests", dependencies: ["MyReadKBridge"])
    ]
)
