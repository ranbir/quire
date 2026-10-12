// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Quire",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "QuireCore"),
        .executableTarget(name: "Quire", dependencies: ["QuireCore"]),
        .testTarget(name: "QuireCoreTests", dependencies: ["QuireCore"]),
    ]
)
