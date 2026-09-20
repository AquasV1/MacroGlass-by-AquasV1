// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacroGlass",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacroGlass",
            path: "Sources/MacroGlass"
        )
    ]
)
