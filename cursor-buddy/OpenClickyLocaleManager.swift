//
//  OpenClickyLocaleManager.swift
//  cursor-buddy
//
//  Runtime language selector for OpenClicky. Original design tried a
//  Bundle.localizedString swizzle for hot-swap, but SwiftUI's per-view
//  executor checks (isMainExecutorImpl) collided with the exchanged
//  IMP inside a background subgraph update and crashed
//  (EXC_BAD_ACCESS in NotchContentView.body). The swizzle is removed.
//
//  Current behaviour:
//    - The user picks Language = System / English / 简体中文 in Settings.
//    - We record the choice in UserDefaults + AppleLanguages.
//    - For an *already-running* session we inject `.environment(\.locale, ...)`
//      into every OpenClicky root SwiftUI hierarchy. SwiftUI honours the
//      environment locale for `Text(verbatim:)` and formatters, but
//      literal-key `Text("...")` lookups against `Bundle.main.localizedString`
//      still read `AppleLanguages`. The user relaunches the app to make
//      every literal switch — this is Apple's recommended pattern for
//      shipped apps.
//
//  Preference key: `openclicky.uiLanguage`.
//    Missing / "system" → follow macOS system language.
//    "en" / "zh-Hans"   → force that locale (persisted via AppleLanguages).
//

import Foundation
import AppKit
import Combine

@MainActor
final class OpenClickyLocaleManager: ObservableObject {
    static let shared = OpenClickyLocaleManager()

    static let userDefaultsKey = "openclicky.uiLanguage"

    @Published private(set) var currentLanguage: String

    var currentLocale: Locale {
        Locale(identifier: currentLanguage)
    }

    /// True if the current in-memory `AppleLanguages` matches what the
    /// user has stored under `openclicky.uiLanguage`. Views can watch
    /// this to know whether a "Relaunch to apply" hint should show.
    var needsRelaunchToApply: Bool {
        guard let stored = UserDefaults.standard.string(forKey: Self.userDefaultsKey),
              stored != "system" else { return false }
        let effective = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first
        return effective != stored
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.userDefaultsKey)
        if let stored, stored != "system" {
            currentLanguage = stored
        } else {
            currentLanguage = Locale.preferredLanguages.first ?? "en"
        }
        // Diagnostic: dump what NSLocalizedString + Bundle.main see
        // right after launch, before any view renders.
        let apple = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String] ?? []
        let preferred = Bundle.main.preferredLocalizations
        let localizations = Bundle.main.localizations
        let sample = NSLocalizedString("Voice controls", comment: "diagnostic")
        let sample2 = Bundle.main.localizedString(forKey: "Voice controls", value: nil, table: nil)
        NSLog("openclicky.locale probe: currentLanguage=%@ apple=%@ preferred=%@ available=%@ NSLoc=%@ bundleLookup=%@",
              currentLanguage,
              String(describing: apple),
              String(describing: preferred),
              String(describing: localizations),
              sample,
              sample2)
    }

    /// Persist the user's chosen language. Only the Settings picker
    /// should call this. Views that need to reflect the choice must
    /// also relaunch (see `relaunchToApply()`) for literal `Text("…")`
    /// lookups to switch — SwiftUI's LocalizedStringKey path is
    /// resolved against `Bundle.main.localizedString` which reads
    /// `AppleLanguages` at process start.
    func setLanguage(_ tag: String) {
        NSLog("openclicky.locale setLanguage tag=%@", tag)
        let defaults = UserDefaults.standard
        if tag == "system" {
            defaults.removeObject(forKey: Self.userDefaultsKey)
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set(tag, forKey: Self.userDefaultsKey)
            defaults.set([tag, "en"], forKey: "AppleLanguages")
        }
        // Explicit synchronize so the values reach disk before the
        // user hits Relaunch. Normally CFPreferences flushes on its
        // own schedule; synchronize() bypasses that so any subsequent
        // process launch reliably sees the write.
        defaults.synchronize()
        currentLanguage = (tag == "system")
            ? (Locale.preferredLanguages.first ?? "en")
            : tag
        NSLog("openclicky.locale after write: uiLanguage=%@ AppleLanguages=%@",
              String(describing: defaults.string(forKey: Self.userDefaultsKey)),
              String(describing: defaults.array(forKey: "AppleLanguages") ?? []))
        objectWillChange.send()
    }

    /// Every language identifier the app has resources for, resolved
    /// at runtime from `Bundle.main.localizations`. Adding a new
    /// locale to `Localizable.xcstrings` (and `CFBundleLocalizations`)
    /// automatically surfaces it in the language picker — no code
    /// change required.
    ///
    /// Filters out Xcode-internal buckets (`Base`) and the development
    /// region duplicate. Order is stable: development region first,
    /// then alphabetically.
    var availableLanguages: [String] {
        // `Bundle.main.localizations` can return duplicates when
        // multiple `.xcstrings` files each contribute the same locale
        // (e.g. Localizable.xcstrings + InfoPlist.xcstrings both list
        // zh-Hans). Dedupe here so the language picker never shows
        // "简体中文" twice.
        let raw = Bundle.main.localizations.filter { $0 != "Base" }
        let dev = Bundle.main.developmentLocalization ?? "en"
        var seen = Set<String>()
        var out: [String] = []
        if raw.contains(dev), seen.insert(dev).inserted {
            out.append(dev)
        }
        for id in raw.sorted() where id != dev {
            if seen.insert(id).inserted {
                out.append(id)
            }
        }
        return out
    }

    /// Human-readable name for a language tag, resolved by the tag's
    /// OWN locale (so zh-Hans reads as "简体中文", not "Chinese
    /// (Simplified)"). Falls back to the tag itself if macOS can't
    /// resolve it.
    func displayName(for languageTag: String) -> String {
        let locale = Locale(identifier: languageTag)
        // Ask each locale to name itself in its own language.
        return locale.localizedString(forLanguageCode: languageTag)
            ?? locale.localizedString(forIdentifier: languageTag)
            ?? languageTag
    }

    /// Compact 2-letter language code for the *active* UI language,
    /// e.g. `"zh"` for `"zh-Hans"` or `"zh-Hans-CN"`. Consumers that
    /// key translation tables by short code (mirage captions, filler
    /// phrases) call this so they do not each hand-roll the trim.
    var shortLanguageCode: String {
        // Locale#language.languageCode?.identifier is macOS 13+.
        if let code = Locale(identifier: currentLanguage).language.languageCode?.identifier {
            return code
        }
        // Fallback: split on '-'.
        return String(currentLanguage.split(separator: "-").first ?? "en")
    }

    /// Look up a short caption for `key` in the callers-supplied
    /// translation table `[key: [langCode: text]]`. Falls back to
    /// English, then to the raw key.
    ///
    /// Consumers pass their own table by reference so we do not
    /// centralise every product string here — the locale manager just
    /// owns the *lookup contract*. Callers that want to migrate to
    /// `Localizable.xcstrings` later swap `t(_:_:)` for
    /// `NSLocalizedString` without touching call sites elsewhere.
    func t(_ key: String, in table: [String: [String: String]]) -> String {
        let lang = shortLanguageCode
        let bucket = table[key] ?? [:]
        return bucket[lang] ?? bucket["en"] ?? key
    }

    /// Pick a random localised choice from `table[langCode] ?? table["en"]`.
    /// Used by filler phrases where each language ships several variants
    /// so back-to-back turns do not always say the same thing.
    func randomChoice(from table: [String: [String]]) -> String? {
        let lang = shortLanguageCode
        let choices = table[lang] ?? table["en"] ?? []
        return choices.randomElement()
    }

    /// Cold-restart the app so `AppleLanguages` takes effect for the
    /// literal `Text("…")` lookups SwiftUI performs. Called from the
    /// "Relaunch" button next to the picker.
    func relaunchToApply() {
        UserDefaults.standard.synchronize()
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
