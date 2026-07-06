// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ABSKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "ABSKit", targets: ["ABSKit"])],
    targets: [
        .target(name: "ABSKit"),
        .testTarget(name: "ABSKitTests", dependencies: ["ABSKit"], resources: [.copy("Fixtures")]),
    ]
)
