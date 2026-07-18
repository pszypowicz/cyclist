// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cyclist",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Cyclist",
            path: "Sources/Cyclist",
            plugins: [.plugin(name: "BuildMetadata")]
        ),
        .plugin(
            name: "BuildMetadata",
            capability: .buildTool()
        ),
    ]
)
