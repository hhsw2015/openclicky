// KitAlias.swift — imports OpenRewindKit alone so we can name Kit's
// `OpenRewindCompressionProfile` unambiguously. OpenRewindKit exports an
// enum named `OpenRewindKit` (the version-holder) which shadows the
// module name when both Kit and Capture are imported in the same file.


typealias KitProfile = OpenRewindCompressionProfile

typealias CapProfile = OpenRewindCompressionProfile

/// Local shim for the daemon's logError. Routes to NSLog since
/// OpenClicky doesn't have the daemon's file-backed logger.
func logError(_ msg: @autoclosure () -> String) {
    NSLog("openrewind_encoder: %@", msg())
}
