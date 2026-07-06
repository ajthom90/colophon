// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SocketSpike",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift", from: "16.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "SocketSpike",
            dependencies: [.product(name: "SocketIO", package: "socket.io-client-swift")]),
    ]
)
