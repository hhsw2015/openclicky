//
//  OpenClickyImagePreprocessor.swift
//  cursor-buddy
//
//  Canonical "shrink to <=maxDim on the long side, JPEG-encode, preserve
//  top-left orientation" helper. Multiple call sites had grown drop-in
//  copies of the same routine (HeyClicky tool client, OpenRewind, MCP
//  bridge, external control, assist agent) — keep the recipe here so
//  changes to interpolation, orientation, or default dimension land in
//  one place.
//
//  Coordinate mapping: the caller is responsible for scaling back click
//  coordinates from the resized image's pixel space to the original
//  screen — this helper returns `(data, width, height)` so the caller
//  can compute `scale = originalW / newW`.
//
//  Reference: clicky-mac `downscaleAndCompressToJPEG`
//  (docs/CLICKY_MAC_REALTIME_SPEC.md §7). Previous copy:
//  HeyClickyChatToolCallClient.swift:671.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum OpenClickyImagePreprocessor {
    /// Downscale + JPEG-encode a source image. Preserves top-left pixel
    /// orientation. Returns nil on any Core Graphics failure.
    static func resizedJPEG(
        source src: Data,
        maxDimension: CGFloat,
        quality: Double
    ) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(src as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return resizedJPEG(cgImage: cgImage, maxDimension: maxDimension, quality: quality)
    }

    static func resizedJPEG(
        cgImage: CGImage,
        maxDimension: CGFloat,
        quality: Double
    ) -> (data: Data, width: Int, height: Int)? {
        let originalWidth = Double(cgImage.width)
        let originalHeight = Double(cgImage.height)
        guard originalWidth > 0, originalHeight > 0 else { return nil }
        let longestSide = max(originalWidth, originalHeight)
        let scale = longestSide > Double(maxDimension) ? Double(maxDimension) / longestSide : 1.0
        let newWidth = max(1, Int((originalWidth * scale).rounded()))
        let newHeight = max(1, Int((originalHeight * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        // CGContext.draw handles the CGImage top-down orientation flip
        // internally, so the encoded JPEG matches what the user saw.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        guard let scaled = context.makeImage() else { return nil }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, scaled, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (outData as Data, newWidth, newHeight)
    }
}
