// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LimitAlert",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LimitAlert",
            path: "Sources"
        ),
    ]
)
