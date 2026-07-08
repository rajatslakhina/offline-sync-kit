// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OfflineSyncKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "OfflineSyncKit",
            targets: ["OfflineSyncKit"]
        )
    ],
    targets: [
        .target(
            name: "OfflineSyncKit",
            dependencies: []
        ),
        .testTarget(
            name: "OfflineSyncKitTests",
            dependencies: ["OfflineSyncKit"]
        )
    ]
)
