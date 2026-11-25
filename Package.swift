// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EdgeStash",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "EdgeStash", targets: ["EdgeStash"])],
    targets: [
        .target(name: "EdgeStashCore"),
        .executableTarget(name: "EdgeStash", dependencies: ["EdgeStashCore"]),
        .executableTarget(name: "EdgeStashChecks", dependencies: ["EdgeStashCore"], path: "Checks")
    ]
)
