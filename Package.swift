// swift-tools-version: 5.8
import PackageDescription
let package = Package(
    name: "WordSlide",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WordSlide", targets: ["WordSlide"])],
    targets: [
        .executableTarget(name: "WordSlide"),
        .testTarget(name: "WordSlideTests", dependencies: ["WordSlide"])
    ]
)
