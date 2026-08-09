// Ported from Everywhere: src/Everywhere.Mac/Mcp/MacInputSimulator.cs + MacKeyCodes.cs + Interop/KeyMapping.cs @30e03e9dcfdd4247fd679828ed86e9042f32d809
//
// XCTest coverage for `InputSimulator`. All tests are headless-safe —
// they exercise the parse / resolve / chunk helpers and the KeyCode
// enum without asking macOS to post real HID events. The single verb
// that does post (`typeText`, `pressKey`, `click`, `scroll`, `drag`)
// is smoke-checked via a `XCTSkipIf` guard so CI without Input
// Monitoring TCC still passes.

import XCTest
import CoreGraphics
@testable import OpenClickyContextService

final class InputSimulatorTests: XCTestCase {

    // MARK: - resolveKey / resolveModifier — table byte-parity

    func test_resolveKey_returnKeyword_maps_to_kVK_Return() {
        XCTAssertEqual(InputSimulator.resolveKey("return"), 0x24)
    }

    func test_resolveKey_enter_alias_matches_return() {
        XCTAssertEqual(InputSimulator.resolveKey("enter"), 0x24)
    }

    func test_resolveKey_escape_and_esc_share_code() {
        XCTAssertEqual(InputSimulator.resolveKey("escape"), 0x35)
        XCTAssertEqual(InputSimulator.resolveKey("esc"), 0x35)
    }

    func test_resolveKey_backspace_and_delete_share_kVK_Delete() {
        // MacKeyCodes.cs — both map to 0x33 (kVK_Delete = Backspace on Mac).
        XCTAssertEqual(InputSimulator.resolveKey("backspace"), 0x33)
        XCTAssertEqual(InputSimulator.resolveKey("delete"), 0x33)
    }

    func test_resolveKey_forwardDelete_via_del_alias() {
        XCTAssertEqual(InputSimulator.resolveKey("del"), 0x75)
        XCTAssertEqual(InputSimulator.resolveKey("forwarddelete"), 0x75)
    }

    func test_resolveKey_arrowKeys() {
        XCTAssertEqual(InputSimulator.resolveKey("up"), 0x7E)
        XCTAssertEqual(InputSimulator.resolveKey("down"), 0x7D)
        XCTAssertEqual(InputSimulator.resolveKey("left"), 0x7B)
        XCTAssertEqual(InputSimulator.resolveKey("right"), 0x7C)
    }

    func test_resolveKey_functionKeys_matchCarbonConstants() {
        XCTAssertEqual(InputSimulator.resolveKey("f1"), 0x7A)
        XCTAssertEqual(InputSimulator.resolveKey("f7"), 0x62)
        XCTAssertEqual(InputSimulator.resolveKey("f12"), 0x6F)
    }

    func test_resolveKey_isCaseInsensitive() {
        XCTAssertEqual(InputSimulator.resolveKey("RETURN"), 0x24)
        XCTAssertEqual(InputSimulator.resolveKey("Escape"), 0x35)
    }

    func test_resolveKey_unknownName_returnsNil() {
        XCTAssertNil(InputSimulator.resolveKey("unknown_key_xyz"))
        XCTAssertNil(InputSimulator.resolveKey(""))
    }

    func test_resolveModifier_cmd_maps_to_maskCommand_and_leftCommandKeycode() {
        let pair = InputSimulator.resolveModifier("cmd")
        XCTAssertNotNil(pair)
        XCTAssertEqual(pair?.0, .maskCommand)
        XCTAssertEqual(pair?.1, 0x37)
    }

    func test_resolveModifier_aliases_command_super_meta_all_map_to_command() {
        for alias in ["cmd", "command", "super", "meta"] {
            let pair = InputSimulator.resolveModifier(alias)
            XCTAssertNotNil(pair, "alias '\(alias)' should resolve")
            XCTAssertEqual(pair?.0, .maskCommand, "alias '\(alias)' should map to .maskCommand")
            XCTAssertEqual(pair?.1, 0x37, "alias '\(alias)' should map to left Command keycode")
        }
    }

    func test_resolveModifier_shift_option_control() {
        XCTAssertEqual(InputSimulator.resolveModifier("shift")?.0, .maskShift)
        XCTAssertEqual(InputSimulator.resolveModifier("shift")?.1, 0x38)

        XCTAssertEqual(InputSimulator.resolveModifier("option")?.0, .maskAlternate)
        XCTAssertEqual(InputSimulator.resolveModifier("alt")?.0, .maskAlternate)
        XCTAssertEqual(InputSimulator.resolveModifier("option")?.1, 0x3A)

        XCTAssertEqual(InputSimulator.resolveModifier("control")?.0, .maskControl)
        XCTAssertEqual(InputSimulator.resolveModifier("ctrl")?.0, .maskControl)
        XCTAssertEqual(InputSimulator.resolveModifier("control")?.1, 0x3B)
    }

    func test_resolveModifier_unknownName_returnsNil() {
        XCTAssertNil(InputSimulator.resolveModifier("hyper"))
        XCTAssertNil(InputSimulator.resolveModifier(""))
    }

    // MARK: - flag-mask byte-parity with CGEventFlags constants

    func test_flagMasks_matchEverywhereMacKeyCodes() {
        // MacKeyCodes.cs L13-16.
        XCTAssertEqual(CGEventFlags.maskShift.rawValue,     0x00020000)
        XCTAssertEqual(CGEventFlags.maskControl.rawValue,   0x00040000)
        XCTAssertEqual(CGEventFlags.maskAlternate.rawValue, 0x00080000)
        XCTAssertEqual(CGEventFlags.maskCommand.rawValue,   0x00100000)
    }

    // MARK: - splitChord / resolveChord

    func test_splitChord_bareKey_hasNoModifiers() throws {
        let (main, mods) = try InputSimulator.splitChord(key: "Return", extraModifiers: [])
        XCTAssertEqual(main, "return")
        XCTAssertTrue(mods.isEmpty)
    }

    func test_splitChord_fusedString_splitsOnPlus() throws {
        let (main, mods) = try InputSimulator.splitChord(key: "cmd+shift+c", extraModifiers: [])
        XCTAssertEqual(main, "c")
        XCTAssertEqual(mods, ["cmd", "shift"])
    }

    func test_splitChord_separateModifiersArg_appliedInOrder() throws {
        let (main, mods) = try InputSimulator.splitChord(
            key: "c",
            extraModifiers: ["cmd", "shift"]
        )
        XCTAssertEqual(main, "c")
        XCTAssertEqual(mods, ["cmd", "shift"])
    }

    func test_splitChord_whitespaceAndCase_arNormalised() throws {
        let (main, mods) = try InputSimulator.splitChord(
            key: "  CMD + Shift + C  ",
            extraModifiers: []
        )
        XCTAssertEqual(main, "c")
        XCTAssertEqual(mods, ["cmd", "shift"])
    }

    func test_splitChord_emptyKey_throwsEmpty() {
        XCTAssertThrowsError(try InputSimulator.splitChord(key: "", extraModifiers: [])) { error in
            XCTAssertEqual(error as? InputSimulator.KeyError, .empty)
        }
        XCTAssertThrowsError(try InputSimulator.splitChord(key: "   ", extraModifiers: [])) { error in
            XCTAssertEqual(error as? InputSimulator.KeyError, .empty)
        }
    }

    func test_resolveChord_cmdC_producesExpectedTuple() throws {
        let (main, mods) = try InputSimulator.splitChord(key: "cmd+c", extraModifiers: [])
        let resolved = try InputSimulator.resolveChord(mainName: main, modifierNames: mods)
        XCTAssertEqual(resolved.main, 0x08) // kVK_ANSI_C
        XCTAssertEqual(resolved.modifiers.count, 1)
        XCTAssertEqual(resolved.modifiers[0].0, .maskCommand)
        XCTAssertEqual(resolved.modifiers[0].1, 0x37)
    }

    func test_resolveChord_cmdShiftC_producesTwoModifiersInOrder() throws {
        let (main, mods) = try InputSimulator.splitChord(key: "cmd+shift+c", extraModifiers: [])
        let resolved = try InputSimulator.resolveChord(mainName: main, modifierNames: mods)
        XCTAssertEqual(resolved.main, 0x08)
        XCTAssertEqual(resolved.modifiers.map { $0.0 }, [.maskCommand, .maskShift])
        XCTAssertEqual(resolved.modifiers.map { $0.1 }, [0x37, 0x38])
    }

    func test_resolveChord_unknownKey_throwsUnknownKey() {
        XCTAssertThrowsError(try InputSimulator.resolveChord(
            mainName: "bogus_key_name",
            modifierNames: []
        )) { error in
            XCTAssertEqual(error as? InputSimulator.KeyError, .unknownKey("bogus_key_name"))
        }
    }

    func test_resolveChord_unknownModifier_throwsUnknownModifier() {
        XCTAssertThrowsError(try InputSimulator.resolveChord(
            mainName: "c",
            modifierNames: ["hyper"]
        )) { error in
            XCTAssertEqual(error as? InputSimulator.KeyError, .unknownModifier("hyper"))
        }
    }

    // MARK: - graphemeChunks — Unicode TR29 correctness

    func test_graphemeChunks_asciiFitsInOneChunk() {
        let chunks = InputSimulator.graphemeChunks("hello", maxUnits: 64)
        XCTAssertEqual(chunks, ["hello"])
    }

    func test_graphemeChunks_emptyStringYieldsNoChunks() {
        XCTAssertTrue(InputSimulator.graphemeChunks("", maxUnits: 64).isEmpty)
    }

    func test_graphemeChunks_flushesBeforeExceedingCap() {
        // 5-char groups, cap 4 → each group flushes early.
        let chunks = InputSimulator.graphemeChunks("aaaaabbbbbccccc", maxUnits: 4)
        // Every chunk must be <= 4 UTF-16 units.
        for c in chunks {
            XCTAssertLessThanOrEqual(c.utf16.count, 4, "chunk '\(c)' exceeds cap")
        }
        // Reassembling gives back the input.
        XCTAssertEqual(chunks.joined(), "aaaaabbbbbccccc")
    }

    func test_graphemeChunks_neverSplitsMidGrapheme_familyEmoji() {
        // ZWJ-joined family emoji: single extended grapheme cluster
        // whose UTF-16 length exceeds any small cap.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        XCTAssertEqual(family.count, 1, "sanity: this is one extended grapheme cluster")
        let chunks = InputSimulator.graphemeChunks(family, maxUnits: 4)
        XCTAssertEqual(chunks, [family],
                       "single grapheme > cap must be emitted intact, never split")
    }

    func test_graphemeChunks_cjkAggregatesToChunks() {
        // Chinese CJK characters each occupy one UTF-16 unit (they are
        // BMP), so with cap=3 the sentence "你好世界" splits into
        // [3, 1] chunks — never mid-character.
        let text = "你好世界"
        let chunks = InputSimulator.graphemeChunks(text, maxUnits: 3)
        XCTAssertEqual(chunks.map { $0.count }, [3, 1])
        XCTAssertEqual(chunks.joined(), text)
    }

    // MARK: - KeyCode enum byte-parity with MacKeyCodes.cs

    func test_keyCode_letters_matchCarbonConstants() {
        XCTAssertEqual(KeyCode.a.rawValue, 0x00)
        XCTAssertEqual(KeyCode.c.rawValue, 0x08)
        XCTAssertEqual(KeyCode.v.rawValue, 0x09)
        XCTAssertEqual(KeyCode.z.rawValue, 0x06)
    }

    func test_keyCode_specialKeys_matchCarbonConstants() {
        XCTAssertEqual(KeyCode.return.rawValue, 0x24)
        XCTAssertEqual(KeyCode.tab.rawValue, 0x30)
        XCTAssertEqual(KeyCode.space.rawValue, 0x31)
        XCTAssertEqual(KeyCode.escape.rawValue, 0x35)
        XCTAssertEqual(KeyCode.delete.rawValue, 0x33)
        XCTAssertEqual(KeyCode.forwardDelete.rawValue, 0x75)
    }

    func test_keyCode_modifiers_matchLeftHandCarbonConstants() {
        XCTAssertEqual(KeyCode.command.rawValue, 0x37)
        XCTAssertEqual(KeyCode.shift.rawValue,   0x38)
        XCTAssertEqual(KeyCode.option.rawValue,  0x3A)
        XCTAssertEqual(KeyCode.control.rawValue, 0x3B)
    }

    func test_keyCode_roundTripsJSON() throws {
        let sample: [KeyCode] = [.return, .escape, .command, .c]
        let data = try JSONEncoder().encode(sample)
        let back = try JSONDecoder().decode([KeyCode].self, from: data)
        XCTAssertEqual(back, sample)
    }

    // MARK: - Smoke tests (skipped when the harness cannot post HID events)

    /// Whether the current process can create HID keyboard events at
    /// all. Sandboxed test runners without Input Monitoring TCC still
    /// tend to succeed at `CGEvent` allocation (the permission check
    /// happens at post time), so this is a best-effort gate — the
    /// deeper truth (event actually delivered) can only be tested
    /// with a real user session. Matches the guard pattern used by
    /// `SelectedTextCaptureTests`.
    private func canAllocateKeyboardEvent() -> Bool {
        return CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) != nil
    }

    func test_typeText_smoke_emptyString_isNoOp() {
        // Empty input must never reach CGEvent; smoke-callable even on
        // fully headless CI.
        InputSimulator.typeText("")
    }

    func test_typeText_smoke_asciiDoesNotCrash() throws {
        try XCTSkipIf(!canAllocateKeyboardEvent(),
                      "cannot allocate CGEvent — headless environment")
        // Post to the void — no assertion; we only verify the call
        // returns cleanly. Real event delivery needs TCC.
        InputSimulator.typeText("hi", delayMs: 0)
    }

    func test_typeText_smoke_unicodeDoesNotCrash() throws {
        try XCTSkipIf(!canAllocateKeyboardEvent(),
                      "cannot allocate CGEvent — headless environment")
        InputSimulator.typeText("你好", delayMs: 0)
    }

    func test_pressKey_smoke_returnKey_doesNotThrow() throws {
        try XCTSkipIf(!canAllocateKeyboardEvent(),
                      "cannot allocate CGEvent — headless environment")
        XCTAssertNoThrow(try InputSimulator.pressKey("Return"))
    }

    func test_pressKey_smoke_cmdC_doesNotThrow() throws {
        try XCTSkipIf(!canAllocateKeyboardEvent(),
                      "cannot allocate CGEvent — headless environment")
        XCTAssertNoThrow(try InputSimulator.pressKey("cmd+c"))
    }

    func test_pressKey_unknownKey_throws_evenOnHeadless() {
        XCTAssertThrowsError(try InputSimulator.pressKey("bogus_key_zzz")) { error in
            XCTAssertEqual(error as? InputSimulator.KeyError, .unknownKey("bogus_key_zzz"))
        }
    }

    func test_pressKey_unknownModifier_throws_evenOnHeadless() {
        XCTAssertThrowsError(try InputSimulator.pressKey("c", modifiers: ["hyper"])) { error in
            XCTAssertEqual(error as? InputSimulator.KeyError, .unknownModifier("hyper"))
        }
    }

    func test_click_smoke_doesNotCrash() throws {
        try XCTSkipIf(!canAllocateKeyboardEvent(),
                      "cannot allocate CGEvent — headless environment")
        InputSimulator.click(at: CGPoint(x: 0, y: 0))
    }

    func test_scroll_smoke_zeroDelta_isNoOp() {
        // Zero delta short-circuits before allocation; always safe.
        InputSimulator.scroll(at: CGPoint(x: 0, y: 0), dx: 0, dy: 0)
    }

    func test_scroll_smoke_doesNotCrash() throws {
        try XCTSkipIf(!canAllocateKeyboardEvent(),
                      "cannot allocate CGEvent — headless environment")
        InputSimulator.scroll(at: CGPoint(x: 0, y: 0), dx: 0, dy: 1)
    }

    func test_drag_smoke_doesNotCrash() throws {
        try XCTSkipIf(!canAllocateKeyboardEvent(),
                      "cannot allocate CGEvent — headless environment")
        InputSimulator.drag(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1, y: 1))
    }

    // MARK: - Regression: Wave-2 fixes (2026-07-23)

    /// F13 Issue #6 — Everywhere chord parser at
    /// `MacInputSimulator.cs:120` does `t.ToLowerInvariant().Replace(
    /// " ", string.Empty)`, so `"page up"` folds to `"pageup"` and
    /// resolves to `0x74`. The Swift port previously only trimmed
    /// outer whitespace and dropped these aliases.
    func test_splitChord_stripsInnerWhitespace_forSpacedAlias() throws {
        let (main, mods) = try InputSimulator.splitChord(
            key: "page up",
            extraModifiers: []
        )
        XCTAssertEqual(main, "pageup",
            "inner whitespace must be stripped so 'page up' resolves to 'pageup'")
        XCTAssertTrue(mods.isEmpty)
        // And the normalised token must resolve through the key table.
        XCTAssertEqual(InputSimulator.resolveKey(main), 0x74)
    }

    func test_splitChord_stripsInnerWhitespace_inExtraModifiers() throws {
        let (main, mods) = try InputSimulator.splitChord(
            key: "c",
            extraModifiers: ["c m d", " shift "]
        )
        XCTAssertEqual(main, "c")
        XCTAssertEqual(mods, ["cmd", "shift"],
            "inner whitespace must be stripped inside extraModifiers too")
    }

    /// F13 Issue #4 — Everywhere at `MacInputSimulator.cs:102` uses
    /// `>`, not `>=`, when deciding whether a single grapheme cluster
    /// must be emitted alone. A cluster whose UTF-16 length exactly
    /// equals the cap must still fit in a chunk without triggering the
    /// pathological-lonely path.
    func test_graphemeChunks_clusterAtExactCap_fitsInOneChunk() {
        // 4 ASCII characters, cap = 4 — should emit a single chunk.
        let chunks = InputSimulator.graphemeChunks("aaaa", maxUnits: 4)
        XCTAssertEqual(chunks, ["aaaa"],
            "cluster totalling exactly `maxUnits` UTF-16 units must fit in one chunk")
    }

    /// F13 Issue #5 — Everywhere `ComputeScrollDelta(pages)` at
    /// `MacInputSimulator.cs:214-219`: `round(12 * pages)` with
    /// `MidpointRounding.AwayFromZero`, clamped to `[1, Int32.max]`.
    func test_computeScrollDelta_matchesEverywhereFormula() {
        // Default pages = 1 → 12.
        XCTAssertEqual(InputSimulator.computeScrollDelta(pages: 1), 12)
        // Half a page rounds away-from-zero: round(6) = 6.
        XCTAssertEqual(InputSimulator.computeScrollDelta(pages: 0.5), 6)
        // Midpoint 0.125 → round(1.5) = 2 (away from zero).
        XCTAssertEqual(InputSimulator.computeScrollDelta(pages: 0.125), 2)
        // Zero pages must still clamp up to 1 (matches `Math.Max(1.0,
        // raw)` in `ComputeScrollDelta`).
        XCTAssertEqual(InputSimulator.computeScrollDelta(pages: 0), 1)
        XCTAssertEqual(InputSimulator.computeScrollDelta(pages: -1), 1)
    }

    /// F13 Issue #5 — new `scroll(at:direction:pages:)` overload
    /// smoke test: with pages=0 clamp still fires, but at 0 x-y
    /// deltas the raw scroll short-circuits, so this is safe on
    /// headless CI.
    func test_scroll_pagesOverload_smoke_zeroPages_isSafe() {
        // Direction irrelevant; delta will be 1 (clamped) but we do
        // not assert delivery, only that the overload compiles + runs.
        InputSimulator.scroll(
            at: CGPoint(x: 0, y: 0),
            direction: .down,
            pages: 0
        )
    }

    /// F13 Issue #3 — `KeyError.eventCreationFailed` shape exists and
    /// carries the failing main-key name. Actual triggering requires a
    /// forced-nil CGEvent which we can't produce in-process; the
    /// existence of the case is enough to guarantee callers can
    /// pattern-match on it.
    func test_pressKey_eventCreationFailed_errorCaseIsAvailable() {
        let err: InputSimulator.KeyError = .eventCreationFailed(key: "return")
        switch err {
        case .eventCreationFailed(let name):
            XCTAssertEqual(name, "return")
        default:
            XCTFail("eventCreationFailed enum case is missing")
        }
    }
}
