// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlayerEngine",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "PlayerEngine", targets: ["PlayerEngine"])],
    dependencies: [.package(path: "../ABSKit")],
    targets: [
        .target(name: "PlayerEngine", dependencies: ["ABSKit"]),
        .testTarget(name: "PlayerEngineTests", dependencies: ["PlayerEngine"]),
    ]
)
