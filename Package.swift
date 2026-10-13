// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Quire",
    platforms: [.macOS("14.4")],
    dependencies: [
        // GitHub's CommonMark + GFM reference parser (gfm branch, pinned)
        .package(url: "https://github.com/apple/swift-cmark", revision: "56146aeeecbfb7ea54504ac6453ac4cbc0faffe7"),
    ],
    targets: [
        .target(name: "QuireMarkdownC", dependencies: [
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
        ]),
        .target(name: "QuireCore", dependencies: [
            "QuireMarkdownC",
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
        ]),
        .executableTarget(name: "Quire", dependencies: ["QuireCore"]),
        .testTarget(name: "QuireCoreTests", dependencies: ["QuireCore"], exclude: ["Spec"]),
    ]
)
