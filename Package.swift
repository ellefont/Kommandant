// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kommandant",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Kommandant", path: "Sources/Kommandant")
    ]
)
