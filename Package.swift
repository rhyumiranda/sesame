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
        // Shared library: storage, log, model, and the Touch ID gate.
        // Both the `sesame` CLI and the `SesameApp` menu-bar app depend on it.
        .target(
            name: "SesameCore"
        ),
        // The `sesame` command-line tool (Milestone 1). Keeps its command +
        // argument-parsing code; imports the shared types from SesameCore.
        .executableTarget(
            name: "sesame",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "SesameCore"
            ]
        ),
        // The Milestone 2 menu-bar (status-bar) app: MenuBarExtra + SMAppService.
        .executableTarget(
            name: "SesameApp",
            dependencies: [
                "SesameCore"
            ]
        ),
        .testTarget(
            name: "sesameTests",
            dependencies: ["sesame", "SesameCore"]
        )
    ]
)
