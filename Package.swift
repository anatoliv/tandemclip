// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tandemclip",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "tandemclip",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/tandemclip",
            linkerSettings: [
                // Find Sparkle.framework inside the packaged .app at runtime.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
