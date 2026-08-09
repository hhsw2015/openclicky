// DateParsing.swift — flexible ISO-8601 / RFC-3339 date parsing.
//
// The MCP schema for date args (`iso8601` in SchemaBuilder) is loose:
// we accept the value as a plain string and validate on the server
// side. Rewind's stored timestamps and callers in the wild use several
// close-but-not-identical formats; rather than force clients to pick
// one, this helper tries the common flavours in order and returns the
// first that parses.
//
// Accepted formats (checked in this order):
//   1. RFC-3339 with fractional seconds and timezone   (2020-01-01T00:00:00.123Z)
//   2. RFC-3339 with timezone                          (2020-01-01T00:00:00Z)
//   3. Naive datetime with fractional seconds          (2020-01-01T00:00:00.123)
//   4. Naive datetime, seconds granularity             (2020-01-01T00:00:00)
//   5. Calendar day                                    (2020-01-01)
//
// Naive datetimes are interpreted in the current time zone, matching
// how Rewind's Reader/UI treat wall-clock stamps.

import Foundation

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoBasic: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func makeNaive(_ pattern: String) -> DateFormatter {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = pattern
    return f
}

private let naiveMillis    = makeNaive("yyyy-MM-dd'T'HH:mm:ss.SSS")
private let naiveSeconds   = makeNaive("yyyy-MM-dd'T'HH:mm:ss")
private let calendarDayFmt = makeNaive("yyyy-MM-dd")

/// Parse a date string in any of the accepted flavours. Returns nil on
/// unrecognised input; callers translate that to a `-32602` params
/// error at the JSON-RPC boundary.
func parseFlexibleDate(_ s: String) -> Date? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let d = isoFractional.date(from: trimmed) { return d }
    if let d = isoBasic.date(from: trimmed)      { return d }
    if let d = naiveMillis.date(from: trimmed)   { return d }
    if let d = naiveSeconds.date(from: trimmed)  { return d }
    if let d = calendarDayFmt.date(from: trimmed) { return d }
    return nil
}
