// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyReadK2Bridge",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "my-read-k2-bridge", targets: ["MyReadK2Bridge"])
    ],
    targets: [
        .executableTarget(
            name: "MyReadK2Bridge",
            linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "MyReadK2BridgeTests", dependencies: ["MyReadK2Bridge"])
    ]
)
