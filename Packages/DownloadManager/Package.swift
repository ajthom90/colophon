// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DownloadManager",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "DownloadManager", targets: ["DownloadManager"])],
    targets: [
        .target(name: "DownloadManager"),
        .testTarget(name: "DownloadManagerTests", dependencies: ["DownloadManager"]),
    ]
)
