// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tandem",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "tandem",
            path: "Sources/tandem"
        )
    ]
)
