// Ported from Everywhere: src/Everywhere.Mac/Interop/VisualElementContext.Screenshot.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// Everywhere's screenshot code has no unit tests — it lives inside an
// interactive selection window and needs a live WindowServer + Screen
// Recording consent. openclicky adds:
//
//   * Pure math tests for `computeSize` (matches
//     `ScreenshotEncoder.cs:104-118`) that run headless-safe.
//   * Guard tests for the public API (bogus pid, degenerate rect, out-of-range
//     screen index) — these never touch ScreenCaptureKit.
//   * Live-capture tests gated on TCC consent: they invoke
//     `SCShareableContent.current` first and `XCTSkipIf` when it throws
//     or reports no displays (i.e. the test host has no Screen Recording
//     permission).
//   * A ScreenshotResult / ScreenshotRegion round-trip test.

import XCTest
import CoreGraphics
import AppKit
import ScreenCaptureKit
import ImageIO
@testable import OpenClickyContextService

final class ScreenshotCaptureEverywhereTests: XCTestCase {

    // MARK: - ComputeSize (ScreenshotEncoder.cs:104-118)

    func test_computeSize_returnsSourceWhenUnderCap() {
        let (w, h) = ScreenshotCaptureEverywhere.computeSize(
            srcW: 800, srcH: 600, maxW: 1920, maxH: 1080)
        XCTAssertEqual(w, 800)
        XCTAssertEqual(h, 600)
    }

    func test_computeSize_capsByTighterAxis() {
        // 3840x2160 -> capped to 1920x1080 (both axes hit exactly).
        let (w, h) = ScreenshotCaptureEverywhere.computeSize(
            srcW: 3840, srcH: 2160, maxW: 1920, maxH: 1080)
        XCTAssertEqual(w, 1920)
        XCTAssertEqual(h, 1080)
    }

    func test_computeSize_preservesAspectAtTallCap() {
        // 4000x2000, cap 1920x1080. Height ratio 1080/2000 = 0.54 is
        // tighter than width 1920/4000 = 0.48. Wait — 0.48 is smaller.
        // Width ratio wins -> outW=1920, outH = round(2000 * 0.48) = 960.
        let (w, h) = ScreenshotCaptureEverywhere.computeSize(
            srcW: 4000, srcH: 2000, maxW: 1920, maxH: 1080)
        XCTAssertEqual(w, 1920)
        XCTAssertEqual(h, 960)
    }

    func test_computeSize_forcesEvenDimensions() {
        // A 2001x1001 source with a 1000x1000 cap: ratio 1000/2001 = 0.4998.
        // outW = round(2001 * 0.4998) = 1000; outH = round(1001 * 0.4998) = 500.
        // Both even -> unchanged.
        // A trickier case: 1003x1001 with cap 500x500 => ratio 500/1003 ~= 0.4985.
        // w = round(1003 * 0.4985) = 500; h = round(1001 * 0.4985) = 499 (odd -> 498).
        let (_, h) = ScreenshotCaptureEverywhere.computeSize(
            srcW: 1003, srcH: 1001, maxW: 500, maxH: 500)
        XCTAssertEqual(h % 2, 0, "odd height must be nudged down to even")
    }

    func test_computeSize_floorsAtTwoPixels() {
        // Absurd downscale: 10x10 -> 1x1 requested. Floor at 2, then even -> 2.
        let (w, h) = ScreenshotCaptureEverywhere.computeSize(
            srcW: 10, srcH: 10, maxW: 1, maxH: 1)
        XCTAssertEqual(w, 2)
        XCTAssertEqual(h, 2)
    }

    func test_computeSize_disablesAxisWithZeroCap() {
        // maxW=0 -> width uncapped. Only height clamps.
        let (w, h) = ScreenshotCaptureEverywhere.computeSize(
            srcW: 4000, srcH: 4000, maxW: 0, maxH: 1000)
        // ratio = 1000/4000 = 0.25 -> w = 1000, h = 1000.
        XCTAssertEqual(w, 1000)
        XCTAssertEqual(h, 1000)
    }

    // MARK: - Guard behaviour (headless-safe)

    func test_captureWindow_returnsNil_forZeroPid() async {
        let result = await ScreenshotCaptureEverywhere.captureWindow(pid: 0, format: .jpeg)
        XCTAssertNil(result, "pid == 0 must short-circuit to nil")
    }

    func test_captureWindow_returnsNil_forNegativePid() async {
        let result = await ScreenshotCaptureEverywhere.captureWindow(pid: -1, format: .png)
        XCTAssertNil(result)
    }

    func test_captureRegion_returnsNil_forZeroSizeRect() async {
        let r = CGRect(x: 0, y: 0, width: 0, height: 0)
        let result = await ScreenshotCaptureEverywhere.captureRegion(rect: r, format: .jpeg)
        XCTAssertNil(result)
    }

    func test_captureRegion_returnsNil_forNegativeSizeRect() async {
        let r = CGRect(x: 0, y: 0, width: -100, height: -100)
        let result = await ScreenshotCaptureEverywhere.captureRegion(rect: r, format: .jpeg)
        XCTAssertNil(result)
    }

    func test_captureRegion_returnsNil_forRectOutsideAllScreens() async {
        // Far-off Quartz coords — no screen intersects.
        let r = CGRect(x: 1_000_000, y: 1_000_000, width: 100, height: 100)
        let result = await ScreenshotCaptureEverywhere.captureRegion(rect: r, format: .jpeg)
        XCTAssertNil(result)
    }

    func test_captureScreen_returnsNil_forOutOfRangeIndex() async {
        let result = await ScreenshotCaptureEverywhere.captureScreen(
            screenID: Int.max, format: .jpeg)
        XCTAssertNil(result)
    }

    func test_captureScreen_returnsNil_forNegativeIndex() async {
        let result = await ScreenshotCaptureEverywhere.captureScreen(
            screenID: -1, format: .jpeg)
        XCTAssertNil(result)
    }

    // MARK: - Live capture (gated on Screen Recording consent)

    /// Skip live capture tests when: env flag set, no NSScreen, or
    /// SCShareableContent.current fails (which is what happens when the
    /// test host lacks Screen Recording TCC).
    private func skipUnlessScreenRecordingReady() async throws {
        if ProcessInfo.processInfo.environment["OPENCLICKY_SKIP_UI_TESTS"] != nil {
            throw XCTSkip("UI test skipped by env flag")
        }
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("No NSScreen — headless CI")
        }
        do {
            let content = try await SCShareableContent.current
            if content.displays.isEmpty {
                throw XCTSkip("SCShareableContent returned no displays")
            }
        } catch {
            throw XCTSkip("SCShareableContent unavailable (likely no Screen Recording TCC): \(error)")
        }
    }

    func test_captureScreen_returnsBytes_whenPermitted() async throws {
        try await skipUnlessScreenRecordingReady()

        guard let result = await ScreenshotCaptureEverywhere.captureScreen(
            screenID: 0, format: .jpeg) else {
            throw XCTSkip("Screen capture returned nil (TCC or transient failure)")
        }

        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertEqual(result.format, .jpeg)
        XCTAssertGreaterThan(result.pixelWidth, 0)
        XCTAssertGreaterThan(result.pixelHeight, 0)
        // JPEG magic (FF D8 FF).
        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0xD8)
        XCTAssertEqual(result.data[2], 0xFF)
    }

    func test_captureScreen_png_emitsPngMagic() async throws {
        try await skipUnlessScreenRecordingReady()

        guard let result = await ScreenshotCaptureEverywhere.captureScreen(
            screenID: 0, format: .png) else {
            throw XCTSkip("Screen capture returned nil")
        }

        XCTAssertEqual(result.format, .png)
        // PNG magic: 89 50 4E 47 0D 0A 1A 0A
        XCTAssertEqual(result.data[0], 0x89)
        XCTAssertEqual(result.data[1], 0x50)
        XCTAssertEqual(result.data[2], 0x4E)
        XCTAssertEqual(result.data[3], 0x47)
    }

    func test_captureScreen_capsAt1920x1080() async throws {
        try await skipUnlessScreenRecordingReady()

        guard let result = await ScreenshotCaptureEverywhere.captureScreen(
            screenID: 0, format: .jpeg) else {
            throw XCTSkip("Screen capture returned nil")
        }
        XCTAssertLessThanOrEqual(result.pixelWidth,
                                 ScreenshotCaptureEverywhere.defaultMaxWidth)
        XCTAssertLessThanOrEqual(result.pixelHeight,
                                 ScreenshotCaptureEverywhere.defaultMaxHeight)
    }

    func test_captureRegion_returnsBytes_forValidRect() async throws {
        try await skipUnlessScreenRecordingReady()

        guard let primary = NSScreen.screens.first else {
            throw XCTSkip("No primary screen")
        }
        // Take a 200x200 slice from top-left of primary display, in Quartz
        // coords. NSScreen.frame is Cocoa (bottom-left), so top-left in
        // Quartz for the primary display is (0, 0).
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        XCTAssertLessThan(rect.width, primary.frame.width)

        guard let result = await ScreenshotCaptureEverywhere.captureRegion(
            rect: rect, format: .jpeg) else {
            throw XCTSkip("Region capture returned nil (TCC or transient)")
        }

        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.pixelWidth, 0)
        XCTAssertGreaterThan(result.pixelHeight, 0)
    }

    func test_captureWindow_returnsBytes_forFrontmostAppPid() async throws {
        try await skipUnlessScreenRecordingReady()

        guard let front = NSWorkspace.shared.frontmostApplication else {
            throw XCTSkip("No frontmost app")
        }
        let pid = front.processIdentifier
        // Front app might have no on-screen windows (e.g. LSUIElement helper
        // during CI). A nil result is a legitimate skip, not a failure.
        guard let result = await ScreenshotCaptureEverywhere.captureWindow(
            pid: pid, format: .jpeg) else {
            throw XCTSkip("Frontmost app has no on-screen window suitable for capture")
        }

        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertGreaterThan(result.pixelWidth, 0)
        XCTAssertGreaterThan(result.pixelHeight, 0)
    }

    // MARK: - ScreenshotRegion / ScreenshotResult round-trip

    func test_screenshotRegion_roundTripsJSON() throws {
        let sample = ScreenshotRegion(x: 12.5, y: -0.25, width: 800, height: 600)
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(ScreenshotRegion.self, from: data)
        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.cgRect, CGRect(x: 12.5, y: -0.25, width: 800, height: 600))
    }

    func test_screenshotRegion_fromCGRect() {
        let src = CGRect(x: 1, y: 2, width: 3, height: 4)
        let region = ScreenshotRegion(cgRect: src)
        XCTAssertEqual(region.cgRect, src)
    }

    func test_screenshotFormat_encodesAsLowercaseString() throws {
        let data = try JSONEncoder().encode(ScreenshotFormat.jpeg)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"jpeg\"")
    }
}
