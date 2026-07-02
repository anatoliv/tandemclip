// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tandemclip",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "tandemclip",
            path: "Sources/tandemclip"
        )
    ]
)
