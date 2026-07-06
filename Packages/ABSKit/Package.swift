// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ABSKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ABSKit", targets: ["ABSKit"]),
        .library(name: "ABSRealtime", targets: ["ABSRealtime"]),
    ],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.1.0"),
    ],
    targets: [
        .target(name: "ABSKit"),
        .target(name: "ABSRealtime",
                dependencies: ["ABSKit", .product(name: "SocketIO", package: "socket.io-client-swift")]),
        .testTarget(name: "ABSKitTests", dependencies: ["ABSKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ABSRealtimeTests", dependencies: ["ABSRealtime"]),
    ]
)
