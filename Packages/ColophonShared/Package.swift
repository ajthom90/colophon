// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ColophonShared",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "ColophonShared", targets: ["ColophonShared"])],
    targets: [
        .target(name: "ColophonShared"),
        .testTarget(name: "ColophonSharedTests", dependencies: ["ColophonShared"]),
    ]
)
