// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "gatea",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git",
                 from: "1.20.0")
    ],
    targets: [
        .executableTarget(
            name: "gatea",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ],
            path: "Sources/gatea"
        )
    ]
)
