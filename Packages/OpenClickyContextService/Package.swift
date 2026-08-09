// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenClickyContextService",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "OpenClickyContextService",
            targets: ["OpenClickyContextService"]
        ),
        .executable(
            name: "openclicky-context-hook",
            targets: ["openclicky-context-hook"]
        )
    ],
    targets: [
        .target(
            name: "OpenClickyContextService",
            dependencies: [],
            path: "Sources/OpenClickyContextService"
        ),
        .executableTarget(
            name: "openclicky-context-hook",
            dependencies: ["OpenClickyContextService"],
            path: "Sources/openclicky-context-hook"
        ),
        .testTarget(
            name: "OpenClickyContextServiceTests",
            dependencies: ["OpenClickyContextService"],
            path: "Tests/OpenClickyContextServiceTests"
        )
    ]
)
