// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LibraryCache",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "LibraryCache", targets: ["LibraryCache"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")],
    targets: [
        .target(name: "LibraryCache", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "LibraryCacheTests", dependencies: ["LibraryCache"]),
    ]
)
