// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "xlb-diff",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "xlb-diff", path: "Sources/xlb-diff"),
    ]
)
