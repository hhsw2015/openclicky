//
//  HeyClickyCoordinateTransform.swift
//  cursor-buddy
//
//  Single source of truth for screenshot-pixel → screen-point → AppKit-
//  global coordinate transforms. Every visual annotation (point / rect /
//  arrow / curve / target) MUST go through these helpers so a point tag
//  and a highlight rect always agree on where "y = 655" is.
//
//  Per protocol spec: coordinates arrive in screenshot pixel space,
//  top-left origin. We rescale into screen-local top-left points using
//  screen.frame.width/height ÷ screenshotWidth/Height, then flip Y once
//  when the caller needs bottom-left AppKit global coords (buddy fly).
//

import AppKit
import Foundation

enum HeyClickyCoordinateTransform {

    /// Resolve the target NSScreen for a beat / point tool call.
    /// 1-based `screen_index` from the walkthrough beat wins; otherwise
    /// the display containing the mouse; otherwise `NSScreen.main`.
    static func targetScreen(preferredIndex: Int?) -> NSScreen? {
        let screens = NSScreen.screens
        if let idx = preferredIndex, idx >= 1, idx <= screens.count {
            return screens[idx - 1]
        }
        let mouse = NSEvent.mouseLocation
        return screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? screens.first
    }

    /// Rescale a screenshot-pixel point into screen-local point space.
    /// The layer that renders (SwiftUI overlay ZStack) uses top-left
    /// origin, so no Y flip here — the annotation is drawn as-is.
    static func rescaleToScreenLocal(
        px: CGFloat,
        py: CGFloat,
        screen: NSScreen,
        screenshotWidth: Int,
        screenshotHeight: Int
    ) -> CGPoint {
        let sw = CGFloat(max(1, screenshotWidth))
        let sh = CGFloat(max(1, screenshotHeight))
        return CGPoint(
            x: px * (screen.frame.width / sw),
            y: py * (screen.frame.height / sh)
        )
    }

    /// Same rescale for a radius (uses the mean of the x/y scales so
    /// hover circles / target rings don't ellipse when the aspect ratio
    /// isn't square).
    static func rescaleRadiusToScreenLocal(
        _ radius: CGFloat,
        screen: NSScreen,
        screenshotWidth: Int,
        screenshotHeight: Int
    ) -> CGFloat {
        let sw = CGFloat(max(1, screenshotWidth))
        let sh = CGFloat(max(1, screenshotHeight))
        let sx = screen.frame.width / sw
        let sy = screen.frame.height / sh
        return radius * ((sx + sy) / 2)
    }

    /// Rescale a screenshot-pixel rect (top-left origin) into a
    /// screen-local rect. Preserves axis alignment even under non-square
    /// scale ratios via corner conversion.
    static func rescaleRectToScreenLocal(
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        h: CGFloat,
        screen: NSScreen,
        screenshotWidth: Int,
        screenshotHeight: Int
    ) -> CGRect {
        let tl = rescaleToScreenLocal(px: x, py: y, screen: screen,
                                      screenshotWidth: screenshotWidth,
                                      screenshotHeight: screenshotHeight)
        let br = rescaleToScreenLocal(px: x + w, py: y + h, screen: screen,
                                      screenshotWidth: screenshotWidth,
                                      screenshotHeight: screenshotHeight)
        return CGRect(
            x: min(tl.x, br.x),
            y: min(tl.y, br.y),
            width: abs(br.x - tl.x),
            height: abs(br.y - tl.y)
        )
    }

    /// Convert a screen-local top-left point into AppKit global bottom-
    /// left coordinates. Used by the buddy fly-to animation which asks
    /// the CGEvent / NSWindow layer for global positions.
    static func toGlobalBottomLeft(_ localPoint: CGPoint, on screen: NSScreen) -> CGPoint {
        CGPoint(
            x: screen.frame.origin.x + localPoint.x,
            y: screen.frame.origin.y + (screen.frame.height - localPoint.y)
        )
    }

    /// One-shot: screenshot px → global AppKit point (for buddy fly).
    /// Callers should use this for `flyBuddyTo` so the point-at-screen
    /// tool and the walkthrough `point` beat land on the same spot.
    static func screenshotPixelToGlobalBottomLeft(
        px: CGFloat,
        py: CGFloat,
        screen: NSScreen,
        screenshotWidth: Int,
        screenshotHeight: Int
    ) -> CGPoint {
        let local = rescaleToScreenLocal(px: px, py: py, screen: screen,
                                          screenshotWidth: screenshotWidth,
                                          screenshotHeight: screenshotHeight)
        return toGlobalBottomLeft(local, on: screen)
    }
}
