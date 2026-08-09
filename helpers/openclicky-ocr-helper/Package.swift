// swift-tools-version: 5.9
//
// openclicky-ocr-helper — out-of-process Vision OCR + SQLCipher FTS
// writer. Runs as an NSXPCConnection XPCService bundle inside
// OpenClicky.app so heavy Vision + ANE work never contends with
// WindowServer inside the main app process.
//
// See helpers/openclicky-ocr-helper/README.md for the embed / signing
// contract with the main-app pbxproj build phase.

import PackageDescription

let package = Package(
    name: "openclicky-ocr-helper",
    platforms: [.macOS("13.0")],
    products: [
        .executable(
            name: "openclicky-ocr-helper",
            targets: ["openclicky-ocr-helper"]
        )
    ],
    dependencies: [
        // Same SQLCipher package the main app links, pinned to the
        // exact version so the helper's DB writes are wire-compatible
        // with the main app's reads (cipher_page_size = 4096).
        .package(
            url: "https://github.com/skiptools/swift-sqlcipher.git",
            exact: "1.7.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "openclicky-ocr-helper",
            dependencies: [
                .product(name: "SQLCipher", package: "swift-sqlcipher")
            ],
            path: "Sources/openclicky-ocr-helper"
        )
    ]
)
