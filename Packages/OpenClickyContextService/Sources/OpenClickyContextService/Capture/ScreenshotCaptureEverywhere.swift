// Ported from Everywhere: src/Everywhere.Mac/Interop/VisualElementContext.Screenshot.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Also references (same commit):
//   src/Everywhere.Mac/Interop/NSScreenVisualElement.cs      - screen enumeration + Cocoa->Quartz Y-flip
//   src/Everywhere.Mcp/Snapshot/ScreenshotEncoder.cs         - JPEG/PNG encode defaults (q=70, 1920x1080)
//   src/Everywhere.Mcp/Tools/ScreenshotTool.cs               - agent-tool public-API defaults
//
// This file is the Everywhere-parity port. openclicky already ships an
// App-side capture utility (`cursor-buddy/CompanionScreenCaptureUtility.swift`)
// and a computer-use runtime capture (`OpenClickyComputerUseRuntime.swift`);
// both remain untouched. This port stands on its own inside the
// ContextService package so router / stash callers get a
// Screen-Recording-safe screenshot API that matches Everywhere's
// encoder contract byte-for-byte.
//
// Everywhere's screenshot pipeline is:
//   1. Enumerate `NSScreen.Screens`, Cocoa->Quartz Y-flip each frame.
//   2. Intersect the requested rect against the union of screen rects.
//   3. Call `CGImage.ScreenImage(0, rect, All, Default)` — deprecated,
//      forbidden by our constraints.
//   4. If that returns null, fall back to `/usr/sbin/screencapture -x -R x,y,w,h`
//      (which itself wraps ScreenCaptureKit under the hood).
//   5. Encode via ImageIO: jpeg@70 by default, 1920x1080 cap, even
//      dims, floor at 2px; png@100 uncapped for OCR/diff.
//
// Our port replaces step 3 with `SCScreenshotManager.captureImage`
// directly (macOS 14+) — the same modern backend `screencapture`
// wraps — and keeps the CLI as a last-resort fallback for parity with
// `NSScreenVisualElement.cs:110-115`.

import Foundation
import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Everywhere-parity screenshot capture. Public API is fixed by the
/// port task; internal helpers mirror the C# helpers one-for-one.
///
/// All three entry points return `nil` on any failure (no throws) —
/// callers that need to distinguish "not permitted" from "empty rect"
/// should probe TCC state separately. This matches Everywhere's
/// `CaptureScreen` in `VisualElementContext.Screenshot.cs:161-212`,
/// which returns `Bitmap?` and swallows both empty-rect and native
/// nil-return cases.
public enum ScreenshotCaptureEverywhere {

    // MARK: Encoder defaults (mirror ScreenshotEncoder.cs:15-19)

    /// JPEG quality default. `ScreenshotEncoder.cs:17` — `Quality = 70`.
    public static let defaultQuality: Int = 70
    /// Max output height. `ScreenshotEncoder.cs:18` — `MaxHeight = 1080`.
    public static let defaultMaxHeight: Int = 1080
    /// Max output width. `ScreenshotEncoder.cs:19` — `MaxWidth = 1920`.
    public static let defaultMaxWidth: Int = 1920

    // MARK: Public API

    /// Capture the top-most on-screen window belonging to `pid`.
    ///
    /// Returns nil when:
    ///   * `pid <= 0`
    ///   * `SCShareableContent.current` fails or lists no matching window
    ///   * The capture itself throws (Screen Recording not granted)
    ///
    /// Mirrors Everywhere's window-capture strategy in
    /// `ScreenshotSession.OnLeftButtonUp` (Screenshot.cs:113-117): pick
    /// the selected element's bounding rect and hand to the underlying
    /// capture. Here we resolve "window for pid" via ScreenCaptureKit's
    /// `SCWindow.owningApplication.processID` instead of walking AX.
    public static func captureWindow(pid: Int32, format: ScreenshotFormat) async -> ScreenshotResult? {
        guard pid > 0 else { return nil }
        guard let content = try? await SCShareableContent.current else { return nil }

        // On-screen, has-a-title (skips shadow windows), owned by pid.
        let candidates = content.windows.filter { win in
            guard let owner = win.owningApplication else { return false }
            return owner.processID == pid && win.isOnScreen && win.frame.width > 1 && win.frame.height > 1
        }
        guard let window = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)
        config.showsCursor = false

        return await captureViaSC(filter: filter, config: config, format: format,
                                   fallbackRect: window.frame)
    }

    /// Capture an arbitrary Quartz-space rectangle across all displays.
    ///
    /// Mirrors `VisualElementContext.Screenshot.cs:166-212`:
    ///   * Build the union of every `NSScreen`'s Quartz-flipped frame.
    ///   * Intersect the requested rect against that union.
    ///   * If the intersection is empty / non-positive -> nil.
    ///   * Otherwise capture the display with the largest intersection
    ///     and crop to `rect`.
    public static func captureRegion(rect: CGRect, format: ScreenshotFormat) async -> ScreenshotResult? {
        guard rect.width > 0, rect.height > 0 else { return nil }

        // Cocoa->Quartz screen enumeration (NSScreenVisualElement.cs:57-67).
        let screens = quartzScreenFrames()
        guard !screens.isEmpty else { return nil }

        // Union + intersect (Screenshot.cs:173-188).
        let union = screens.reduce(CGRect.null) { $0.union($1.quartzFrame) }
        let clipped = rect.intersection(union)
        guard !clipped.isNull, !clipped.isEmpty, clipped.width > 0, clipped.height > 0 else {
            return nil
        }

        // Pick display with largest intersection.
        var host = screens[0]
        var bestArea: CGFloat = 0
        for s in screens {
            let i = s.quartzFrame.intersection(clipped)
            if i.isNull || i.isEmpty { continue }
            let a = i.width * i.height
            if a > bestArea { bestArea = a; host = s }
        }

        guard let content = try? await SCShareableContent.current,
              let scDisplay = content.displays.first(where: { $0.displayID == host.displayID })
                              ?? content.displays.first else {
            return await captureViaCLI(rect: clipped, format: format)
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()

        // Source rect is in the display's local coordinate space (top-left origin).
        let localX = clipped.origin.x - host.quartzFrame.origin.x
        let localY = clipped.origin.y - host.quartzFrame.origin.y
        config.sourceRect = CGRect(x: localX, y: localY, width: clipped.width, height: clipped.height)
        config.width = Int(clipped.width * host.backingScale)
        config.height = Int(clipped.height * host.backingScale)
        config.showsCursor = false

        return await captureViaSC(filter: filter, config: config, format: format,
                                   fallbackRect: clipped)
    }

    /// Capture an entire display.
    ///
    /// `screenID` is an *index* into `NSScreen.screens` (0 = primary).
    /// This mirrors Everywhere's `CaptureAndSetBackground` iteration in
    /// `Screenshot.cs:47-59` which walks `NSScreen.Screens` by index.
    ///
    /// Returns nil when the index is out of range or SC capture fails
    /// and the CLI fallback also fails.
    public static func captureScreen(screenID: Int = 0, format: ScreenshotFormat) async -> ScreenshotResult? {
        let screens = quartzScreenFrames()
        guard screenID >= 0, screenID < screens.count else { return nil }
        let host = screens[screenID]

        guard let content = try? await SCShareableContent.current else {
            return await captureViaCLI(rect: host.quartzFrame, format: format)
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == host.displayID })
                              ?? (screenID < content.displays.count ? content.displays[screenID] : nil) else {
            return await captureViaCLI(rect: host.quartzFrame, format: format)
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(host.quartzFrame.width * host.backingScale)
        config.height = Int(host.quartzFrame.height * host.backingScale)
        config.showsCursor = false

        return await captureViaSC(filter: filter, config: config, format: format,
                                   fallbackRect: host.quartzFrame)
    }

    // MARK: SC capture path

    /// Run `SCScreenshotManager.captureImage`, then hand the CGImage to
    /// the encoder. On any throw or nil, fall back to the CLI path
    /// (mirrors `NSScreenVisualElement.cs:93-115` where CGImage.ScreenImage
    /// null-return triggers the screencapture fallback).
    private static func captureViaSC(
        filter: SCContentFilter,
        config: SCStreamConfiguration,
        format: ScreenshotFormat,
        fallbackRect: CGRect
    ) async -> ScreenshotResult? {
        do {
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return encode(cgImage: cgImage, format: format)
        } catch {
            return await captureViaCLI(rect: fallbackRect, format: format)
        }
    }

    // MARK: CLI fallback (NSScreenVisualElement.cs:118-163)

    /// `/usr/sbin/screencapture -x -R x,y,w,h /tmp/....png` fallback.
    ///
    /// This is a byte-for-byte port of `CaptureViaScreencaptureCli`
    /// (`NSScreenVisualElement.cs:118-163`): 3s wait, kill on timeout,
    /// silent (`-x`), rect flag (`-R`), temp file wiped in finally.
    /// The comment there notes ScreenCaptureKit lives under this CLI,
    /// which is why it works when `SCScreenshotManager` refuses.
    private static func captureViaCLI(rect: CGRect, format: ScreenshotFormat) async -> ScreenshotResult? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("openclicky-cap-\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = [
            "-x",
            "-R", "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))",
            tmp.path,
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        do {
            try proc.run()
        } catch {
            return nil
        }

        // 3s bounded wait, kill on timeout (Everywhere line 141-145).
        let deadline = Date().addingTimeInterval(3.0)
        while proc.isRunning {
            if Date() > deadline {
                proc.terminate()
                return nil
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tmp.path),
              let src = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }

        return encode(cgImage: cg, format: format)
    }

    // MARK: Encode (ScreenshotEncoder.cs:71-118)

    /// Encode a CGImage with Everywhere's default caps.
    ///
    /// Steps mirror `ScreenshotEncoder.Encode`:
    ///   1. `ComputeSize` — cap by tighter axis, floor at 2px, force even.
    ///   2. Downscale via CGContext if capped.
    ///   3. Encode via ImageIO. JPEG uses
    ///      `kCGImageDestinationLossyCompressionQuality`.
    static func encode(cgImage: CGImage, format: ScreenshotFormat) -> ScreenshotResult? {
        let srcW = cgImage.width
        let srcH = cgImage.height
        let (outW, outH) = computeSize(srcW: srcW, srcH: srcH,
                                        maxW: defaultMaxWidth, maxH: defaultMaxHeight)

        let scaled: CGImage
        if outW == srcW && outH == srcH {
            scaled = cgImage
        } else {
            guard let redrawn = redraw(cgImage, to: CGSize(width: outW, height: outH)) else {
                return nil
            }
            scaled = redrawn
        }

        let uti: CFString
        switch format {
        case .jpeg: uti = UTType.jpeg.identifier as CFString
        case .png:  uti = UTType.png.identifier as CFString
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, uti, 1, nil) else { return nil }

        var props: [CFString: Any] = [:]
        if format == .jpeg {
            let q = max(1, min(100, defaultQuality))
            props[kCGImageDestinationLossyCompressionQuality] = Double(q) / 100.0
        }
        CGImageDestinationAddImage(dest, scaled, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return ScreenshotResult(
            data: data as Data,
            format: format,
            pixelWidth: outW,
            pixelHeight: outH
        )
    }

    /// Compute output size honouring `defaultMaxWidth` / `defaultMaxHeight`.
    /// 1:1 with `ScreenshotEncoder.ComputeSize` (`ScreenshotEncoder.cs:104-118`).
    ///
    /// A `max <= 0` disables that axis' cap. Result is floored at 2px,
    /// then rounded down to even (yuv420p downstream requires even).
    static func computeSize(srcW: Int, srcH: Int, maxW: Int, maxH: Int) -> (Int, Int) {
        let ratioW: Double = (maxW > 0 && srcW > maxW) ? Double(maxW) / Double(srcW) : 1.0
        let ratioH: Double = (maxH > 0 && srcH > maxH) ? Double(maxH) / Double(srcH) : 1.0
        let ratio = min(ratioW, ratioH)
        if ratio >= 1.0 { return (srcW, srcH) }
        var w = max(2, Int((Double(srcW) * ratio).rounded()))
        var h = max(2, Int((Double(srcH) * ratio).rounded()))
        if w % 2 != 0 { w -= 1 }
        if h % 2 != 0 { h -= 1 }
        return (w, h)
    }

    /// Redraw a CGImage at a new size using CoreGraphics (equivalent to
    /// Everywhere's Skia surface downscale in `ScreenshotEncoder.cs:84-99`).
    private static func redraw(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                        CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: Screen enumeration (NSScreenVisualElement.cs:53-68)

    /// A single display in Quartz coordinates plus its CoreGraphics
    /// `displayID` and backing scale — enough info for both display
    /// intersection (Screenshot.cs:173-188) and building an
    /// `SCContentFilter`.
    struct ScreenFrame {
        let displayID: CGDirectDisplayID
        let quartzFrame: CGRect
        let backingScale: CGFloat
    }

    /// Enumerate `NSScreen.screens` and convert Cocoa (bottom-left) to
    /// Quartz (top-left). Mirrors `NSScreenVisualElement.BoundingRectangle`
    /// (`NSScreenVisualElement.cs:53-68`).
    static func quartzScreenFrames() -> [ScreenFrame] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height

        return screens.compactMap { s -> ScreenFrame? in
            guard let numberVal = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let cocoa = s.frame
            let quartz = CGRect(
                x: cocoa.origin.x,
                y: primaryHeight - (cocoa.origin.y + cocoa.height),
                width: cocoa.width,
                height: cocoa.height
            )
            return ScreenFrame(
                displayID: CGDirectDisplayID(numberVal.uint32Value),
                quartzFrame: quartz,
                backingScale: s.backingScaleFactor
            )
        }
    }
}
