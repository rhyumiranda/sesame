// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sesame",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "sesame",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "sesameTests",
            dependencies: ["sesame"]
        )
    ]
)
