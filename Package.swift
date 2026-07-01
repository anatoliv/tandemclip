// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "clipboardd",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "clipboardd",
            path: "Sources/clipboardd"
        )
    ]
)
