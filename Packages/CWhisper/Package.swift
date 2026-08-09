// swift-tools-version: 5.9
import PackageDescription

let libPath = "/Users/wowdd1/Dev/openclicky/Vendors/whisper/lib"

let package = Package(
    name: "CWhisper",
    products: [.library(name: "CWhisper", targets: ["CWhisper"])],
    targets: [
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", libPath,
                    "-lwhisper", "-lggml", "-lggml-base",
                    "-lggml-cpu", "-lggml-metal", "-lggml-blas",
                    "-rpath", libPath,
                ])
            ]
        )
    ]
)
