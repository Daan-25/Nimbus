// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Nimbus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Nimbus", path: "Sources/Nimbus")
    ]
)
