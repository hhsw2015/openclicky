# Review F13: InputSimulator (native, for LaunchPhrase)

**Everywhere pin**: 30e03e9dcfdd4247fd679828ed86e9042f32d809
**openclicky files**:
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/InputSimulator.swift`
- `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift:2474-2542` (KeyCode enum)

**Everywhere files**:
- `src/Everywhere.Mac/Mcp/MacInputSimulator.cs` (389 lines)
- `src/Everywhere.Mac/Mcp/MacKeyCodes.cs` (105 lines)
- `src/Everywhere.Mac/Interop/KeyMapping.cs` (107 lines) — not a functional analogue; port target is CGEvent, not Avalonia

**Reviewer**: F13 review agent
**Date**: 2026-07-23

## Alignment Table

| Aspect | openclicky | Everywhere | Match | Note |
|---|---|---|---|---|
| File header cites Everywhere @ pin | `InputSimulator.swift:1` | — | ✅ | Header line references `MacInputSimulator.cs + MacKeyCodes.cs + Interop/KeyMapping.cs @30e03e9d` |
| Event tap | `.cghidEventTap` throughout (`InputSimulator.swift:159,169,177,189,248,396,397,414`) | `CGEventTapLocation.HidEventTap = 0` (`MacInputSimulator.cs:231,296`) | ✅ | HID-level; matches `kCGHIDEventTap` raw 0 |
| Non-targeted event source | `.hidSystemState` (`InputSimulator.swift:214,238,263`) | `CGEventSourceStateID.HidSystemState = 1` (`MacInputSimulator.cs:20,291`) | ✅ | Openclicky is pid-less by design (documented in header) |
| Modifier flags | `.maskShift`/`.maskControl`/`.maskAlternate`/`.maskCommand` via `CGEventFlags` (`InputSimulator.swift:510-518`) | `0x00020000 / 0x00040000 / 0x00080000 / 0x00100000` (`MacKeyCodes.cs:13-16`) | ✅ | CGEventFlags raw values match |
| VkCommand/Shift/Option/Control keycodes | `0x37 / 0x38 / 0x3A / 0x3B` (`InputSimulator.swift:510-518`) | `0x37 / 0x38 / 0x3A / 0x3B` (`MacKeyCodes.cs:47`) | ✅ | Byte-parity |
| Letter keycodes a-z | `InputSimulator.swift:458-464` | `MacKeyCodes.cs:19-25, 51-57` | ✅ | Byte-parity all 26 |
| Digit keycodes 0-9 | `InputSimulator.swift:467-469` | `MacKeyCodes.cs:26-28, 58-60` | ✅ | Byte-parity |
| `return`/`enter` = 0x24 | `InputSimulator.swift:472` | `MacKeyCodes.cs:30, 62` | ✅ | |
| `tab` = 0x30 | `InputSimulator.swift:473` | `MacKeyCodes.cs:30, 63` | ✅ | |
| `space`/`spacebar` = 0x31 | `InputSimulator.swift:474` | `MacKeyCodes.cs:30, 64` | ✅ | |
| `escape`/`esc` = 0x35 | `InputSimulator.swift:475` | `MacKeyCodes.cs:30, 65` | ✅ | |
| `backspace`/`delete` = 0x33 | `InputSimulator.swift:476` | `MacKeyCodes.cs:31, 66` | ✅ | |
| `del`/`forwarddelete` = 0x75 | `InputSimulator.swift:477` | `MacKeyCodes.cs:31, 67` | ✅ | |
| `insert` = 0x72 (Help) | `InputSimulator.swift:478` | `MacKeyCodes.cs:31, 68` (`VkHelp = 0x72`) | ✅ | |
| Arrows up/down/left/right | `0x7E/0x7D/0x7B/0x7C` (`InputSimulator.swift:480`) | `MacKeyCodes.cs:32, 70` | ✅ | |
| `home`/`end` = 0x73/0x77 | `InputSimulator.swift:481` | `MacKeyCodes.cs:33, 71` | ✅ | |
| `pageup`/`page_up`/`prior` = 0x74 | `InputSimulator.swift:482` | `MacKeyCodes.cs:33, 72` | ✅ | |
| `pagedown`/`page_down`/`next` = 0x79 | `InputSimulator.swift:483` | `MacKeyCodes.cs:33, 73` | ✅ | |
| `caps_lock` = 0x39 | `InputSimulator.swift:484` | `MacKeyCodes.cs:34, 74` | ✅ | |
| f1-f12 | `InputSimulator.swift:487-489` | `MacKeyCodes.cs:36-38, 76-78` | ✅ | Byte-parity |
| `kp_0`-`kp_9` | `InputSimulator.swift:492-494` | `MacKeyCodes.cs:40-42, 80-82` | ✅ | |
| `kp_enter`/`kp_equal`/`kp_multiply` | `0x4C/0x51/0x43` (`InputSimulator.swift:495`) | `MacKeyCodes.cs:43, 83` | ✅ | |
| `kp_add`/`kp_subtract`/`kp_decimal` | `0x45/0x4E/0x41` (`InputSimulator.swift:496`) | `MacKeyCodes.cs:44, 84` | ✅ | |
| `kp_divide`/`kp_delete` = 0x4B/0x41 | `InputSimulator.swift:497` | `MacKeyCodes.cs:45, 85` | ✅ | `kp_delete` aliases `VkKeypadDecimal`, byte-matched |
| `kp_home` = 0x73 | `InputSimulator.swift:498` | `MacKeyCodes.cs:86` | ✅ | |
| `kp_left`/`kp_up`/`kp_right`/`kp_down` | `0x7B/0x7E/0x7C/0x7D` (`InputSimulator.swift:498-499`) | `MacKeyCodes.cs:86-87` | ✅ | |
| `kp_prior`/`kp_page_up` = 0x74 | `InputSimulator.swift:500` | `MacKeyCodes.cs:88` | ✅ | |
| `kp_next`/`kp_page_down` = 0x79 | `InputSimulator.swift:501` | `MacKeyCodes.cs:89` | ✅ | |
| `kp_end`/`kp_insert` = 0x77/0x72 | `InputSimulator.swift:502` | `MacKeyCodes.cs:90` | ✅ | |
| Modifier aliases (`cmd`/`command`/`super`/`meta`) | `InputSimulator.swift:510-513` | `MacKeyCodes.cs:95-98` | ✅ | Four-way alias on Command |
| Modifier aliases (`shift`, `option`/`alt`, `control`/`ctrl`) | `InputSimulator.swift:514-518` | `MacKeyCodes.cs:99-103` | ✅ | |
| `typeText` chunk cap = 64 UTF-16 units | `maxUnitsPerChunk = 64` (`InputSimulator.swift:433`) | `const int Max = 64` (`MacInputSimulator.cs:87`) | ✅ | |
| Grapheme walk | Swift `for cluster in text` (`InputSimulator.swift:286`) — TR29 extended grapheme cluster | `StringInfo.GetTextElementEnumerator(text)` (`MacInputSimulator.cs:89`) — TR29 | ✅ | Both TR29-compliant, so ZWJ/flags/family emoji survive intact |
| Inter-chunk sleep in TypeText | Floored at 20 ms (`minChunkDelayMicros = 20_000`, `InputSimulator.swift:437`); DEFAULT `delayMs = 30 ms` (`InputSimulator.swift:113`) → effective 30 ms | Fixed `Thread.Sleep(20)` (`MacInputSimulator.cs:96,105`) | ⚠️ | Openclicky default is 30 ms; matches PostMouse cadence, NOT Everywhere's TypeText 20 ms. Documented at `InputSimulator.swift:108-112` but this IS a real deviation from Everywhere's TypeText |
| Post-chord sleep = 100 ms | `postChordDelayMicros = 100_000` (`InputSimulator.swift:440`) | `Thread.Sleep(100)` (`MacInputSimulator.cs:181`) | ✅ | |
| Post-mouse sleep = 30 ms | `postMouseDelayMicros = 30_000` (`InputSimulator.swift:443`) | `Thread.Sleep(30)` (`MacInputSimulator.cs:251`) | ✅ | |
| Post-scroll sleep = 100 ms | `postScrollDelayMicros = 100_000` (`InputSimulator.swift:446`) | `Thread.Sleep(100)` (`MacInputSimulator.cs:211`) | ✅ | |
| Drag interpolation steps = 10 | `dragInterpolationSteps = 10` (`InputSimulator.swift:450`) | Hard-coded `step <= 10` (`MacInputSimulator.cs:63`) | ✅ | Same lerp shape `p = step / 10.0` |
| Drag lerp math | `from + (to − from) * p` (`InputSimulator.swift:269-270`) | `fromX + (toX - fromX) * p` (`MacInputSimulator.cs:67-68`) | ✅ | |
| Click sequence | MouseMoved → downType → upType, all with clickState=clickCount (`InputSimulator.swift:218-220`) | Same (`MacInputSimulator.cs:46-48`) | ✅ | |
| MouseEventClickState field | `.mouseEventClickState` (`InputSimulator.swift:413`) | `CGEventField.MouseEventClickState = 1` (`MacInputSimulator.cs:247, 329`) | ✅ | |
| Scroll wire shape | `scrollWheelEvent2Source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0` (`InputSimulator.swift:239-246`) | `CGEventCreateScrollWheelEvent2(_, Line, 2, w1, w2, 0)` (`MacInputSimulator.cs:201-203`) | ✅ | Wheel1=vertical, wheel2=horizontal; axis assignment matches |
| Mouse button map | `.left→(.left, .leftMouseDown, .leftMouseUp)` etc (`InputSimulator.swift:418-427`) | `MacInputSimulator.cs:234-239` | ✅ | left/right/middle map to (Left/Right/Center) + Down/Up event types |
| xdotool chord parsing (fused `"cmd+shift+c"`) | Split on `+`, last token = main key (`InputSimulator.swift:340-353`) | `xdotoolKeyName.Split('+', ...); tokens[^1]; tokens[..^1]` (`MacInputSimulator.cs:118-127`) | ✅ | |
| Modifier keydown loop (order + flag accumulation) | Forward order; `activeFlags.insert(flag)` BEFORE post; `ev.flags = activeFlags` (`InputSimulator.swift:151-160`) | Forward order; `activeFlags \|= flag` BEFORE post; `CGEventSetFlags(ev, activeFlags)` (`MacInputSimulator.cs:141-149`) | ✅ | |
| Modifier keyup loop (flag-clearing order relative to post) | `activeFlags.remove(flag)` **BEFORE** `ev.flags = activeFlags` + post (`InputSimulator.swift:181-190`) | `CGEventSetFlags(ev, activeFlags)` + `PostEvent` **BEFORE** `activeFlags &= ~flag` (`MacInputSimulator.cs:169-178`) | ❌ | REAL DIVERGENCE — openclicky posts keyup event with the flag already cleared; Everywhere posts keyup event with the flag still set. See Issues #1 |
| CGEvent creation failure handling in pressKey | `guard let … else { continue }` (silently skips a failed modifier `InputSimulator.swift:157, 187`); main key branch silently swallows (`:163-178`) | `throw new InvalidOperationException(...)` on any nil handle (`MacInputSimulator.cs:145, 154-158, 174`) | ⚠️ | Openclicky is more permissive; documented obliquely at header line but not called out as a divergence |
| `graphemeChunks` boundary for cluster == maxUnits | `clusterUnits >= maxUnits` treats a cluster of exactly 64 units as oversize and emits it alone (`InputSimulator.swift:288`) | `grapheme.Length > Max` (strict `>`, `MacInputSimulator.cs:102`) treats exactly 64 as fitting; appends to buffer | ⚠️ | Edge-case behaviour on 64-unit grapheme differs. See Issues #4 |
| KeyCode enum matches Carbon `kVK_*` byte-for-byte | `CaptureTypes.swift:2487-2542` | Everywhere's `MacKeyCodes.cs:19-47` constants | ✅ | Codable JSON enum shape only; not directly consumed by `InputSimulator.pressKey` (which uses the string lookup table) |
| Public API scope | `typeText`, `pressKey`, `click`, `scroll`, `drag`, plus internal `graphemeChunks`/`splitChord`/`resolveChord`/`resolveKey`/`resolveModifier` | `MoveTo`, `Click`, `DragTo`, `TypeText`, `PressKey`, `Scroll` + P/Invoke bag | ⚠️ | Openclicky drops `MoveTo` and `Scroll(direction, pages)` sugar. Move covered by external callers; scroll uses raw dx/dy instead of `ComputeScrollDelta`. Documented in header |
| `MoveTo` cursor-move-only verb | Not implemented | `MacInputSimulator.cs:17-28` | ⚠️ | No LaunchPhrase caller needs this; documented as out-of-scope in file header (`InputSimulator.swift:5-14`). Intentional deviation |
| `ComputeScrollDelta(pages)` = `round(12 * pages)` clamped `[1, int.MaxValue]` | Not implemented; callers pass raw dx/dy | `MacInputSimulator.cs:214-219` | ⚠️ | Openclicky's `scroll(at:dx:dy:)` moves the pages→delta transform to the caller. Not present in header rationale; see Issues #5 |
| Targeted (per-pid) `CGEventPostToPid` variants | Not implemented; all events use `.cghidEventTap` | Optional `targetPid` throughout, dispatched by `PostEvent` (`MacInputSimulator.cs:228-232`) | ⚠️ | Documented as intentional deviation at file header (`InputSimulator.swift:29-31`) — openclicky is pid-less by design |

## Issues Found

- **HIGH #1**: In `pressKey`, the modifier key-up post carries the wrong `CGEventFlags` payload versus Everywhere. Openclicky (`InputSimulator.swift:181-190`) calls `activeFlags.remove(flag)` **before** assigning `ev.flags = activeFlags` and posting. Everywhere (`MacInputSimulator.cs:169-178`) posts the keyup event with the flag still asserted and only clears `activeFlags &= ~flag` afterwards. The two produce different observable flag states on the release event, which some apps read to decide "was the modifier still held at release time?". → **Fix**: reorder to post first with the flag still set, then `activeFlags.remove(flag)`:
  ```swift
  for (flag, modCode) in resolvedModifiers.reversed() {
      guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: modCode, keyDown: false) else {
          activeFlags.remove(flag); continue
      }
      ev.flags = activeFlags
      ev.post(tap: .cghidEventTap)
      activeFlags.remove(flag)
  }
  ```

- **MEDIUM #2**: `typeText` default `delayMs = 30` (`InputSimulator.swift:113`) exceeds Everywhere's fixed `Thread.Sleep(20)` (`MacInputSimulator.cs:96,105`). The header comment (`InputSimulator.swift:108-112`) documents this as "matches Everywhere PostMouse cadence used for click verbs" but the Everywhere function this port mirrors is `TypeText`, not `PostMouse`. Effective throughput of typed text is 1.5× slower per chunk. → **Fix**: change signature default to `delayMs: Int = 20` (still floored at 20 ms internally), or drop the parameter entirely.

- **MEDIUM #3**: Openclicky's `pressKey` silently swallows CGEvent creation failures (`InputSimulator.swift:153-190` — guard/`continue` and unpaired-if blocks). Everywhere throws `InvalidOperationException` (`MacInputSimulator.cs:145, 154-158, 174`). A LaunchPhrase press that fails halfway through the modifier sequence will emit a partial chord and no diagnostic. → **Fix**: propagate a `KeyError.eventCreationFailed` throw when any `CGEvent(...)` returns nil after modifiers are down, so the caller can detect the broken chord.

- **LOW #4**: `graphemeChunks` uses `clusterUnits >= maxUnits` (`InputSimulator.swift:288`) for the "oversize single cluster" branch; Everywhere uses `grapheme.Length > Max` (`MacInputSimulator.cs:102`). A cluster of exactly 64 UTF-16 units is emitted alone by openclicky and appended-then-flushed by Everywhere. Practically unreachable (no known 64-unit grapheme in Unicode), but strict byte-parity fails. → **Fix**: change to `clusterUnits > maxUnits`.

- **LOW #5**: `scroll(at:dx:dy:)` accepts raw wheel deltas; Everywhere's `Scroll(direction, pages)` computes `delta = round(12 * pages)` clamped `[1, int.MaxValue]` (`MacInputSimulator.cs:216-218`). Callers of openclicky's scroll must reproduce this scaling. File header does not mention the intentional relocation. → **Fix**: either document the omission in the header, or expose a `scroll(at:direction:pages:)` sugar that applies the same 12× scaling.

- **LOW #6**: Everywhere's `PressKey` uses `t.ToLowerInvariant().Replace(" ", "")` (`MacInputSimulator.cs:120`) — strips **all** internal spaces from every token before lookup. Openclicky trims only leading/trailing whitespace on each token (`.trimmingCharacters(in: .whitespaces)`, `InputSimulator.swift:342`). A token like `"page up"` (internal space) resolves in Everywhere (matches `pageup`? no — Everywhere strips spaces to become `pageup`, which IS in the dict) but not in openclicky (stays `"page up"`, not in dict). → **Fix**: replace `.trimmingCharacters(in: .whitespaces)` with `.replacingOccurrences(of: " ", with: "")` on each token.

- **INFO**: File header prose (`InputSimulator.swift:1-43`) is partially corrupted — blocks of text appear elided (lines 33-38, 91-190 inline comments in the earlier version we sampled). Contents are still parsable but the formatting is degraded relative to peer files. Cosmetic; no runtime impact.

## Verdict

- [ ] BYTE_MATCH — Swift port is byte-equivalent modulo language syntax
- [ ] SEMANTIC_MATCH — logic identical, some Swift idiomatic reshaping OK
- [x] DIVERGENT — has intentional deviations documented in file header (no targeted-pid variant, no `MoveTo`, no scroll-delta helper) **PLUS** one unintentional bug (Issue #1: modifier keyup flag ordering) and several small deviations (Issues #2-#6). One of these is semantically observable to any app that inspects `CGEventFlags` on modifier release.
- [ ] BROKEN — real bug, needs fix before ship

Practical assessment: **DIVERGENT trending BROKEN once Issue #1 is exercised by an app that reads modifier release flags** (e.g. some IME / global shortcut dispatch code paths). LaunchPhrase's target uses (typing text, pressing return / arrow keys) are unlikely to notice, so the failure will be silent for the current caller set.

## Recommendations

Prioritised fix list:
1. **Issue #1** — reorder `activeFlags.remove(flag)` after post in the modifier keyup loop. Trivial, one-liner. Restore byte-parity with Everywhere.
2. **Issue #6** — swap trimming for internal-space stripping to accept `"page up"`, `"kp equal"`, etc. Trivial.
3. **Issue #2** — reset `typeText` default to 20 ms (or drop the parameter). Trivial.
4. **Issue #3** — surface a throwing path for `CGEvent(...) == nil` failures inside `pressKey` so LaunchPhrase can log a broken chord instead of dispatching a partial one.
5. **Issue #4** — flip `>=` to `>` in `graphemeChunks`.
6. **Issue #5** — either add a `Scroll(direction, pages)` overload with 12× scaling, or note the omission in the file header.
