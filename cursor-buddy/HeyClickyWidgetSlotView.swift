//
//  HeyClickyWidgetSlotView.swift
//  cursor-buddy
//
//  Renders HeyClicky Free tool-call widgets inside the OpenClicky
//  ClickyResponseCardCompactView. IDA-verified widget kinds (see
//  HeyClicky-1.0.40): place, stock, calendar, music, flight. Payload
//  keys are best-effort — the proxy emits Google Places / iTunes /
//  Alpha Vantage style fields, so lookups try the common variants
//  before falling back to a plain "type" caption.
//
//  Style follows OpenClicky DS tokens (dark surface2 fill, medium
//  radius, borderSubtle stroke, secondary text for hints) so widgets
//  feel native to the panel rather than iOS-stock like the real app.
//

import SwiftUI
import OpenClickyUI
import AppKit

struct HeyClickyWidgetSlotView: View {
    let widgets: [WidgetPayload]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(widgets.enumerated()), id: \.offset) { _, widget in
                widgetRow(widget)
            }
        }
    }

    @ViewBuilder
    private func widgetRow(_ widget: WidgetPayload) -> some View {
        switch widget.type {
        case "place", "places":
            // Real server payload is `kind: "places"` with items array
            // under `payload.items`. Older singular `place` shape still
            // accepted for defensive fallback.
            PlaceWidgetRow(payload: widget.payload)
        case "stock":
            StockWidgetRow(payload: widget.payload)
        case "calendar":
            CalendarWidgetRow(payload: widget.payload)
        case "music":
            MusicWidgetRow(payload: widget.payload)
        case "flight":
            FlightWidgetRow(payload: widget.payload)
        default:
            UnknownWidgetRow(type: widget.type ?? "widget", payload: widget.payload)
        }
    }
}

// MARK: - Payload helpers

private enum WidgetField {
    static func string(_ payload: [String: OpenClickyJSONValue], _ keys: String...) -> String? {
        for key in keys {
            if case .string(let value)? = payload[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func double(_ payload: [String: OpenClickyJSONValue], _ keys: String...) -> Double? {
        for key in keys {
            switch payload[key] {
            case .double(let value): return value
            case .int(let value): return Double(value)
            case .string(let value): return Double(value)
            default: continue
            }
        }
        return nil
    }

    static func url(_ payload: [String: OpenClickyJSONValue], _ keys: String...) -> URL? {
        for key in keys {
            if case .string(let value)? = payload[key],
               let url = URL(string: value),
               url.scheme?.hasPrefix("http") == true {
                return url
            }
        }
        return nil
    }
}

// MARK: - Common row chrome

private struct WidgetRowContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }
}

private struct WidgetActionPill: View {
    let title: String
    let systemImageName: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImageName {
                    Image(systemName: systemImageName)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(LocalizedStringKey(title))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}

private struct WidgetThumbnail: View {
    let url: URL?
    let systemFallback: String

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
    }

    private var fallbackIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(DS.Colors.surface3)
            Image(systemName: systemFallback)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }
}

// MARK: - Place

private struct PlaceWidgetRow: View {
    let rawPayload: [String: OpenClickyJSONValue]

    init(payload: [String: OpenClickyJSONValue]) {
        self.rawPayload = payload
    }

    /// The server ships the `places` widget as `payload.items = [...]`
    /// with each element carrying the place fields (name, formatted_address,
    /// photos, rating, etc). We render the first place for a compact row.
    /// Older payload shape may have flat fields on the widget itself —
    /// fall back to that too.
    private var payload: [String: OpenClickyJSONValue] {
        if case .array(let items)? = rawPayload["items"],
           case .object(let first)? = items.first {
            return first
        }
        return rawPayload
    }

    var body: some View {
        WidgetRowContainer {
            HStack(alignment: .center, spacing: DS.Spacing.md) {
                WidgetThumbnail(url: photoURL, systemFallback: "mappin.and.ellipse")
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(name))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    if let address {
                        Text(address)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                WidgetActionPill(title: "Maps", systemImageName: "arrow.up.right.square") {
                    openInMaps()
                }
            }
        }
    }

    private var name: String {
        WidgetField.string(payload, "name", "title", "place_name", "display_name") ?? "Place"
    }
    private var address: String? {
        WidgetField.string(payload, "formatted_address", "address", "vicinity", "subtitle")
    }
    private var photoURL: URL? {
        // Real server payload for `places` widget carries a `photos`
        // array of {reference, width, height} objects — no direct URL.
        // Google Places photos need a separate signed fetch we can't
        // do client-side, so we just fall through to fallback icon.
        // Older payload shapes might expose `photo_url` / `image_url`
        // directly; try those first.
        WidgetField.url(payload, "photo_url", "image_url", "thumbnail", "icon")
    }

    private func openInMaps() {
        let query = address ?? name
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "maps://?q=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Stock

private struct StockWidgetRow: View {
    let payload: [String: OpenClickyJSONValue]

    var body: some View {
        WidgetRowContainer {
            HStack(alignment: .center, spacing: DS.Spacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ticker)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                    if let name {
                        Text(LocalizedStringKey(name))
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(priceString)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(changeString)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(changeColor)
                }
            }
        }
    }

    private var ticker: String {
        WidgetField.string(payload, "symbol", "ticker", "code") ?? "—"
    }
    private var name: String? {
        WidgetField.string(payload, "company_name", "name", "company", "long_name")
    }
    private var price: Double? {
        WidgetField.double(payload, "price", "last", "current_price", "regular_market_price")
    }
    private var changePct: Double? {
        WidgetField.double(payload, "change_percent", "changePercent", "regular_market_change_percent", "pct_change")
    }
    private var priceString: String {
        price.map { String(format: "%.2f", $0) } ?? "—"
    }
    private var changeString: String {
        guard let pct = changePct else { return "" }
        let sign = pct >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", pct))%"
    }
    private var changeColor: Color {
        guard let pct = changePct else { return DS.Colors.textSecondary }
        return pct >= 0 ? DS.Colors.success : DS.Colors.warning
    }
}

// MARK: - Calendar

private struct CalendarWidgetRow: View {
    let payload: [String: OpenClickyJSONValue]

    var body: some View {
        WidgetRowContainer {
            HStack(alignment: .center, spacing: DS.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.surface3)
                        .frame(width: 40, height: 40)
                    Image(systemName: "calendar")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(eventTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(LocalizedStringKey(subtitle))
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                WidgetActionPill(title: "Calendar", systemImageName: "arrow.up.right.square") {
                    openCalendar()
                }
            }
        }
    }

    private var eventTitle: String {
        WidgetField.string(payload, "title", "summary", "name") ?? "Event"
    }
    private var subtitle: String? {
        WidgetField.string(payload, "when", "time", "start_time", "location")
    }

    private func openCalendar() {
        if let url = URL(string: "ical://") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Music

private struct MusicWidgetRow: View {
    let payload: [String: OpenClickyJSONValue]

    var body: some View {
        WidgetRowContainer {
            HStack(alignment: .center, spacing: DS.Spacing.md) {
                WidgetThumbnail(url: artworkURL, systemFallback: "music.note")
                VStack(alignment: .leading, spacing: 2) {
                    Text(track)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    if let artist {
                        Text(artist)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let url = openURL {
                    WidgetActionPill(title: "Play", systemImageName: "play.fill") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var track: String {
        WidgetField.string(payload, "track", "title", "song", "name") ?? "Track"
    }
    private var artist: String? {
        WidgetField.string(payload, "artist", "artist_name", "album_artist")
    }
    private var artworkURL: URL? {
        WidgetField.url(payload, "artwork_url", "image_url", "album_art", "thumbnail")
    }
    private var openURL: URL? {
        WidgetField.url(payload, "url", "apple_music_url", "spotify_url", "preview_url")
    }
}

// MARK: - Flight

private struct FlightWidgetRow: View {
    let payload: [String: OpenClickyJSONValue]

    var body: some View {
        WidgetRowContainer {
            HStack(alignment: .center, spacing: DS.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.surface3)
                        .frame(width: 40, height: 40)
                    Image(systemName: "airplane")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(flightNumber)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(route)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let status {
                    Text(LocalizedStringKey(status))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(statusColor.opacity(0.16)))
                }
            }
        }
    }

    private var flightNumber: String {
        WidgetField.string(payload, "flight_number", "number", "iata", "code") ?? "Flight"
    }
    private var origin: String? {
        WidgetField.string(payload, "origin", "from", "departure_airport", "departure")
    }
    private var destination: String? {
        WidgetField.string(payload, "destination", "to", "arrival_airport", "arrival")
    }
    private var route: String {
        switch (origin, destination) {
        case let (o?, d?): return "\(o) → \(d)"
        case let (o?, nil): return o
        case let (nil, d?): return d
        default: return ""
        }
    }
    private var status: String? {
        WidgetField.string(payload, "status", "state")
    }
    private var statusColor: Color {
        switch status?.lowercased() {
        case "on time", "scheduled", "active": return DS.Colors.success
        case "delayed", "diverted": return DS.Colors.warning
        case "cancelled", "canceled": return DS.Colors.warning
        default: return DS.Colors.textSecondary
        }
    }
}

// MARK: - Unknown

private struct UnknownWidgetRow: View {
    let type: String
    let payload: [String: OpenClickyJSONValue]

    var body: some View {
        WidgetRowContainer {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                Text(type.capitalized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("\(payload.count) fields")
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }
}
