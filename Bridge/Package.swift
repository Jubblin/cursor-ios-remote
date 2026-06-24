// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CursorBridge",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CursorBridge",
            path: "Sources/CursorBridge"
        ),
    ]
)
