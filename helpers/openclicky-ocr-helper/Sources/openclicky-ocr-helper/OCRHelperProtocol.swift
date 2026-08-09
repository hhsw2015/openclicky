// OCRHelperProtocol — shared XPC surface between the main OpenClicky
// app and the openclicky-ocr-helper XPCService bundle. The main app
// declares the same @objc protocol on its side (see
// cursor-buddy/OpenRewind/Capture/OCRHelperClient.swift). NSXPCConnection
// binds by protocol name at runtime, so keeping the two declarations
// byte-identical is load-bearing.
//
// Payload shape:
//   cgImagePNG  PNG-encoded frame bytes, cheap for the caller to make
//               via CGImageDestination and small enough for XPC to move
//               without shared memory. A 1600 px downsample of a retina
//               3456x2160 shot is ~200-400 KB.
//   bundleID    Frontmost app id at capture time. Used by the tile
//               cache to invalidate on foreground-app change.
//   frameID     Row id in the `frame` table the helper attaches
//               searchRanking + node rows to.
//   segmentID   Row id in the `segment` table for doc_segment linkage.
//   tsMillis    Unix milliseconds when the frame was captured.
//   title       Window title stored in searchRanking.title.
//
// Callback returns (ok, error). error is nil on success.

import Foundation

@objc public protocol OpenClickyOCRHelperProtocol {
    func process(cgImagePNG: Data,
                 bundleID: String?,
                 frameID: Int64,
                 segmentID: Int64,
                 tsMillis: Int64,
                 title: String?,
                 reply: @escaping (_ ok: Bool, _ error: String?) -> Void)

    /// Optional ping to verify the connection is live without doing
    /// any Vision or DB work. Returns the helper's process id.
    func ping(reply: @escaping (_ pid: Int32) -> Void)
}
