//
//  AssistAgentPriorImage.swift
//  cursor-buddy
//
//  prior-as-image pipeline. Port of heyclicky_agent/native_render.py.
//  Converts long prior text into a grayscale JPEG so the model can
//  "see" the history via vision tokens — cheaper than sending the
//  same text as prompt tokens for Fable-5 through the HeyClicky proxy.
//

import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

public enum AssistAgentPriorImage {

    // Page geometry — matches pxpipe defaults exactly.
    public static let maxHeightPx = 728
    public static let padX = 4
    public static let padY = 4
    public static let cols = 312
    public static var pageWidthPx: Int {
        padX * 2 + cols * AssistAgentAtlas.shared.cellW
    }

    // MARK: - Section cache

    private static let cacheLock = NSLock()
    private static var cache: [String: (bytes: Data, height: Int)] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheMax = 12

    private static func cacheGet(_ key: String) -> (bytes: Data, height: Int)? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[key]
    }

    private static func cachePut(_ key: String, bytes: Data, height: Int) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache[key] != nil { return }
        cache[key] = (bytes, height)
        cacheOrder.append(key)
        while cacheOrder.count > cacheMax {
            let old = cacheOrder.removeFirst()
            cache.removeValue(forKey: old)
        }
    }

    // MARK: - Public API

    /// Render one text section to raw grayscale bytes (no JPEG). Cached
    /// by content hash — repeat sections cost O(1). Returns the raw
    /// bytes and the total height in px; width is always pageWidthPx.
    public static func renderSectionGray(_ text: String) -> (bytes: Data, height: Int) {
        let atlas = AssistAgentAtlas.shared
        guard atlas.loaded else { return (Data(), 0) }
        let key = sha256Prefix(text)
        if let hit = cacheGet(key) { return hit }

        let pages = layoutTextToPages(text)
        if pages.isEmpty {
            let placeholder = Data(repeating: 0xFF, count: pageWidthPx * 8)
            cachePut(key, bytes: placeholder, height: 8)
            return (placeholder, 8)
        }
        var stacked = Data()
        var totalH = 0
        for page in pages {
            stacked.append(page.gray)
            totalH += page.height
        }
        cachePut(key, bytes: stacked, height: totalH)
        return (stacked, totalH)
    }

    /// Render N sections independently (cache-friendly) then vertically
    /// concat and encode ONE grayscale JPEG at `quality`. Unchanged
    /// sections reuse cached bytes; only diff sections re-blit.
    public static func renderSectionsToJPEG(_ sections: [String],
                                            quality: Double = 0.65)
        -> (jpeg: Data, width: Int, height: Int, pageCount: Int)?
    {
        let atlas = AssistAgentAtlas.shared
        guard atlas.loaded else { return nil }
        var totalGray = Data()
        var totalH = 0
        for section in sections {
            let (bytes, h) = renderSectionGray(section)
            totalGray.append(bytes)
            totalH += h
        }
        guard totalH > 0 else { return nil }
        let w = pageWidthPx
        guard let jpeg = encodeGrayJPEG(bytes: totalGray, width: w, height: totalH,
                                        quality: quality) else {
            return nil
        }
        return (jpeg, w, totalH, sections.count)
    }

    /// Convenience — render a single blob as one JPEG.
    public static func renderTextToJPEG(_ text: String, quality: Double = 0.65)
        -> (jpeg: Data, width: Int, height: Int, pageCount: Int)?
    {
        renderSectionsToJPEG([text], quality: quality)
    }

    // MARK: - Layout

    private struct RenderedPage {
        let width: Int
        let height: Int
        let gray: Data
    }

    private static func layoutTextToPages(_ text: String) -> [RenderedPage] {
        let atlas = AssistAgentAtlas.shared
        let cellW = atlas.cellW
        let cellH = atlas.cellH
        let rowsPerPage = (maxHeightPx - 2 * padY) / cellH
        let nlCP = newlineSymbolCodepoint()
        let spaceRank = atlas.rank(of: 0x20)

        // Build rows first — each row is [(rank, widthCells)].
        var allRows: [[(rank: Int, wc: Int)]] = []
        var curRow: [(rank: Int, wc: Int)] = []
        var curRowWidth = 0

        func flushRow() {
            allRows.append(curRow)
            curRow.removeAll(keepingCapacity: true)
            curRowWidth = 0
        }

        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                let nlRank = atlas.rank(of: nlCP)
                if nlRank >= 0 && curRowWidth + 1 <= cols {
                    curRow.append((nlRank, 1))
                }
                flushRow()
                continue
            }
            if scalar == "\r" { continue }
            var r = atlas.rank(of: UInt32(scalar.value))
            if r < 0 { r = spaceRank }
            if r < 0 { continue }
            let wc = atlas.widthCells(rank: r)
            if curRowWidth + wc > cols { flushRow() }
            curRow.append((r, wc))
            curRowWidth += wc
        }
        if !curRow.isEmpty { flushRow() }

        // Slice into pages.
        var pages: [RenderedPage] = []
        let w = pageWidthPx
        var start = 0
        while start < allRows.count {
            let end = min(start + rowsPerPage, allRows.count)
            let rowsHere = Array(allRows[start..<end])
            let h = padY * 2 + rowsHere.count * cellH
            var gray = Data(repeating: 0xFF, count: w * h)
            gray.withUnsafeMutableBytes { raw in
                let ptr = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for (rowIdx, row) in rowsHere.enumerated() {
                    let yPx = padY + rowIdx * cellH
                    var xPx = padX
                    for (rank, wc) in row {
                        atlas.blit(rank: rank, into: ptr,
                                   pageWidth: w, pageHeight: h,
                                   x: xPx, y: yPx)
                        xPx += wc * cellW
                    }
                }
            }
            pages.append(RenderedPage(width: w, height: h, gray: gray))
            start = end
        }
        return pages
    }

    private static func newlineSymbolCodepoint() -> UInt32 {
        // U+21B5 (↵) if present, else '<'.
        if AssistAgentAtlas.shared.rank(of: 0x21B5) >= 0 { return 0x21B5 }
        return 0x3C
    }

    // MARK: - JPEG encode

    private static func encodeGrayJPEG(bytes: Data, width: Int, height: Int,
                                       quality: Double) -> Data? {
        // Wrap the grayscale bytes as a CGImage, then re-encode as JPEG.
        let provider = CGDataProvider(data: bytes as CFData)
        guard let provider else { return nil }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let cg = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Utilities

    private static func sha256Prefix(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// (entries, approx_bytes) for observability.
    public static func cacheStats() -> (entries: Int, bytes: Int) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let bytes = cache.values.reduce(0) { $0 + $1.bytes.count }
        return (cache.count, bytes)
    }
}
