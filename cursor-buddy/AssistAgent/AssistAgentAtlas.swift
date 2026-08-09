//
//  AssistAgentAtlas.swift
//  cursor-buddy
//
//  Bitmap-font atlas loader for the assist agent's prior-as-image
//  pipeline. The atlas is a single flat resource `assist_agent_atlas.bin`
//  living in AppResources/OpenClicky/ — generated from
//  heyclicky_agent/_atlas_data.py by the Stage-4 build step so we don't
//  have to translate 11k lines of base64 to Swift literals.
//
//  Layout (little-endian):
//    magic:  8B "OCATLAS1"
//    u32:    cell_w, cell_h, ascent, num_glyphs
//    u32 x8: (off, len) pairs for codepoints, offsets, wide_flags, pixels
//    payload: concatenated blobs
//
//  Semantics ported from heyclicky_agent/native_render.py:
//    · codepoints[i] u32 LE — sorted; binary-search to `rank`
//    · offsets[i]    u32 LE — bit offset into pixels[] for glyph i
//    · wide_flags    bit-packed — 1 bit per glyph, MSB-first
//    · pixels        bit-packed — glyph = CELL_H rows × (CELL_W or 2×CELL_W) cols
//

import Foundation

public final class AssistAgentAtlas {
    public static let shared = AssistAgentAtlas()

    public let cellW: Int
    public let cellH: Int
    public let ascent: Int
    public let numGlyphs: Int
    public let loaded: Bool

    private let codepoints: [UInt32]      // sorted
    private let offsets: [UInt32]         // parallel to codepoints
    private let wideFlags: [UInt8]        // bit-packed per glyph
    private let pixels: [UInt8]           // bit-packed pixels

    private init() {
        guard let url = Self.locateResource(),
              let data = try? Data(contentsOf: url),
              data.count >= 8 + 16 + 32,
              data.subdata(in: 0..<8) == Data("OCATLAS1".utf8) else {
            self.cellW = 5; self.cellH = 8; self.ascent = 7; self.numGlyphs = 0
            self.codepoints = []; self.offsets = []
            self.wideFlags = []; self.pixels = []
            self.loaded = false
            return
        }
        func u32(_ at: Int) -> UInt32 {
            data.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }
        }
        self.cellW = Int(u32(8))
        self.cellH = Int(u32(12))
        self.ascent = Int(u32(16))
        self.numGlyphs = Int(u32(20))

        let pairsStart = 24
        func pair(_ i: Int) -> (Int, Int) {
            (Int(u32(pairsStart + i * 8)), Int(u32(pairsStart + i * 8 + 4)))
        }
        let (cpOff, cpLen) = pair(0)
        let (ofOff, ofLen) = pair(1)
        let (wfOff, wfLen) = pair(2)
        let (pxOff, pxLen) = pair(3)

        self.codepoints = Self.readU32Array(data, off: cpOff, len: cpLen)
        self.offsets    = Self.readU32Array(data, off: ofOff, len: ofLen)
        self.wideFlags  = Array(data.subdata(in: wfOff..<(wfOff + wfLen)))
        self.pixels     = Array(data.subdata(in: pxOff..<(pxOff + pxLen)))
        self.loaded = self.numGlyphs > 0
    }

    private static func locateResource() -> URL? {
        // Preferred: bundled AppResources/OpenClicky/assist_agent_atlas.bin.
        // Copy-Resources build phase drops the whole AppResources tree
        // into the app bundle under `AppResources/`.
        if let bundleURL = Bundle.main.resourceURL {
            let candidates = [
                bundleURL.appendingPathComponent("AppResources/OpenClicky/assist_agent_atlas.bin"),
                bundleURL.appendingPathComponent("assist_agent_atlas.bin"),
            ]
            for c in candidates where FileManager.default.fileExists(atPath: c.path) {
                return c
            }
        }
        // Dev fallback — repo path (only present in Debug builds run
        // from Xcode inside the workspace).
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AppResources/OpenClicky/assist_agent_atlas.bin")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    private static func readU32Array(_ data: Data, off: Int, len: Int) -> [UInt32] {
        let count = len / 4
        var out = [UInt32](repeating: 0, count: count)
        data.subdata(in: off..<(off + len)).withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt32.self)
            for i in 0..<count { out[i] = src[i] }
        }
        return out
    }

    // MARK: - Public glyph queries

    /// Binary-search sparse codepoint table. Returns -1 when absent.
    public func rank(of codepoint: UInt32) -> Int {
        var lo = 0, hi = codepoints.count
        while lo < hi {
            let m = (lo + hi) >> 1
            if codepoints[m] < codepoint { lo = m + 1 } else { hi = m }
        }
        if lo < codepoints.count && codepoints[lo] == codepoint { return lo }
        return -1
    }

    /// 1 for narrow, 2 for wide (East-Asian Wide flag).
    public func widthCells(rank: Int) -> Int {
        guard rank >= 0 && rank < numGlyphs else { return 1 }
        let byte = wideFlags[rank >> 3]
        let bit = 7 - (rank & 7)
        return ((byte >> bit) & 1) == 1 ? 2 : 1
    }

    /// Blit one glyph into a grayscale page (0 = black glyph, 255 = bg).
    public func blit(rank: Int,
                     into page: UnsafeMutablePointer<UInt8>,
                     pageWidth w: Int,
                     pageHeight h: Int,
                     x xPx: Int,
                     y yPx: Int) {
        guard rank >= 0 && rank < numGlyphs else { return }
        let bitOffset = Int(offsets[rank])
        let srcW = widthCells(rank: rank) * cellW
        for row in 0..<cellH {
            let py = yPx + row
            if py < 0 || py >= h { continue }
            let rowBit = bitOffset + row * srcW
            for col in 0..<srcW {
                let bitIdx = rowBit + col
                let byteIdx = bitIdx >> 3
                if byteIdx >= pixels.count { continue }
                let bitOff = 7 - (bitIdx & 7)
                if ((pixels[byteIdx] >> bitOff) & 1) == 1 {
                    let px = xPx + col
                    if px >= 0 && px < w {
                        page[py * w + px] = 0  // black
                    }
                }
            }
        }
    }
}
