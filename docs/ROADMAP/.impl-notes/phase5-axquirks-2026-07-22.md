# Phase 5 - AXQuirksInstaller investigation notes (2026-07-22)

Task: port Everywhere's `SetAppBoolAttribute` + call-site quirk-installer to
Swift as `AXQuirksInstaller.swift`. Covers roadmap rows 20 and 21 of
`docs/ROADMAP/01_LAYER_0_CONTEXT_CAPTURE.md`.

## Ground truth (Everywhere @30e03e9d)

### Primitive: `AXUIElement.SetAppBoolAttribute`

`src/Everywhere.Mac/Interop/AXUIElement.cs:1178-1203` (comment L1179-1184):

```csharp
public static bool SetAppBoolAttribute(int pid, string attributeName, bool value)
{
    if (pid <= 0) return false;
    var appHandle = CreateApplication(pid);
    if (appHandle == 0) return false;
    try
    {
        var cfBool = value ? GetCFBooleanTrue() : GetCFBooleanFalse();
        if (cfBool == 0) return false;
        using var nsAttr = new Foundation.NSString(attributeName);
        var err = SetAttributeValue(appHandle, nsAttr.Handle, cfBool);
        return err == AXError.Success;
    }
    finally { CFInterop.CFRelease(appHandle); }
}
```

Key invariants:
- pid `<= 0` -> immediate failure (bool false), never crashes.
- Uses CoreFoundation `kCFBooleanTrue` / `kCFBooleanFalse` singletons.
  The comment (L1181-1184) explicitly notes that
  `AXUIElementSetAttributeValue` REJECTS `NSNumber(true)` for these
  private attributes — only the CFBoolean singleton is accepted. This is
  the same bug OCCU had to work around in
  `AccessibilitySnapshot.swift:352-358`.
- Success is `AXError.Success` (== `kAXErrorSuccess`). Any other AXError
  is treated as failure and returned as `false` — never throws.
- Application AXUIElement is released in `finally` (parity with the
  ARC-managed CFRelease we get for free in Swift).

### Call-site: `VisualElementContext.TryEnableBestEffortAccessibility`

`src/Everywhere.Mac/Interop/VisualElementContext.cs:113-130`:

```csharp
public bool TryEnableBestEffortAccessibility(int processId)
{
    if (processId <= 0) return false;
    var manualOk   = AXUIElement.SetAppBoolAttribute(processId, "AXManualAccessibility",  true);
    var enhancedOk = AXUIElement.SetAppBoolAttribute(processId, "AXEnhancedUserInterface", true);
    return manualOk || enhancedOk;
}
```

- Fires BOTH `AXManualAccessibility` and `AXEnhancedUserInterface`
  unconditionally. There is NO per-app matching — Everywhere does not
  branch on bundle_id.
- Order is documented: `AXManualAccessibility` first,
  `AXEnhancedUserInterface` second. See the "Chrome/Chromium /
  Electron" comment at `VisualElementContext.TextSelection.cs:261-265`
  which explains why both attributes exist (Chromium needs
  `EnhancedUserInterface`; Electron needs `ManualAccessibility`), but
  the call site sets both because we don't know which family owns the
  pid.
- Returns "OR" — success if either one landed. Because these attributes
  are private, the first-time call on some apps returns .failure even
  though the internal state flip does still happen; Everywhere accepts
  this by treating it as success-if-either.

### Guard: memoisation & timeout

`src/Everywhere.Mcp/Tools/AppResolver.cs:12-53`:

```csharp
private static readonly ConcurrentDictionary<int, bool> _a11yEnabledPids = new();

private static void EnsureA11yEnabledOnce(IVisualElementContext ctx, int pid)
{
    if (pid <= 0) return;
    if (!_a11yEnabledPids.TryAdd(pid, true)) return; // cache hit

    var task = Task.Run(() =>
    {
        try { ctx.TryEnableBestEffortAccessibility(pid); } catch { }
    });
    try { task.Wait(TimeSpan.FromMilliseconds(1500)); }
    catch { /* timeout — abandon. */ }
}
```

Comments explicitly note (L31-42) that `AXUIElementSetAttributeValue`
is SYNCHRONOUS and BLOCKING; Notes/Finder/Electron can take 30+s the
FIRST time it fires because the AX subsystem is being rebuilt. The
1500 ms wait is a bounded-wait — if it doesn't return, execution
continues; the system keeps working in the background so the SECOND
call on the same pid observes the upgraded tree.

Idempotency guarantee:
- `TryAdd` returns false on the second call for the same pid, so the
  installer is invoked at most once per (pid, process-lifetime).
- The task-and-timeout wrapper is a caller-side concern; Everywhere
  keeps it OUT of `SetAppBoolAttribute` itself.

### Per-app quirks (roadmap row 21)

`src/Everywhere.Mcp/Snapshot/SnapshotRenderer.cs:241-252`:

```csharp
private static string DisplayRole(IVisualElement el)
{
    return type switch
    {
        VisualElementType.Hyperlink => "link",
        VisualElementType.Document  => "HTML 内容",
        VisualElementType.RadioButton when !string.IsNullOrEmpty(name) => "",
        _ => type.ToString(),
    };
}
```

Note: this is NOT a per-bundle-id quirk table. It is a per-VisualElement-
TYPE remap. It lives inside the snapshot renderer, not the
accessibility-quirks installer. So roadmap row 21 ("per-app quirks") is
already covered by the SnapshotRenderer port (out of scope for this
package until we port the renderer) and does NOT need to live in
`AXQuirksInstaller.swift`. The installer's only job is roadmap row 20.

## Global side-effects

- Setting `AXManualAccessibility` / `AXEnhancedUserInterface` triggers a
  full AX subsystem rebuild in the target process. Once flipped, the
  effect PERSISTS for the lifetime of the target process — flipping it
  back to `false` would only affect subsequent walks. We never unset.
- Blocking-call warning documented above (AppResolver.cs). Callers on
  the openclicky side should mirror the 1500 ms bounded-wait pattern
  when the installer is fired from a UI thread. `installIfNeeded` in
  this port is a synchronous, best-effort call — the timeout wrapper
  lives at the caller level (mirroring Everywhere's separation of
  concerns).

## Attribute name provenance

`src/Everywhere.Mac/Interop/AXAttributeConstants.cs:30-31`:

```csharp
public static readonly NSString EnhancedUserInterface  = new("AXEnhancedUserInterface");
public static readonly NSString ManualAccessibility    = new("AXManualAccessibility");
```

Byte-identical string constants. No aliases, no versioned names.

## Port plan

1. New file `Capture/AXQuirksInstaller.swift`:
   - `public enum AXQuirksInstaller`
   - `public static func installIfNeeded(pid: Int32) throws`
   - `public static func setBoolAttribute(pid: Int32, attribute: String, value: Bool) throws`
   - Per-pid installed-set behind an `NSLock` (matches the
     `ConcurrentDictionary` semantic Everywhere uses).
2. Append `AXQuirkInfo` to `Types/CaptureTypes.swift` so downstream
   callers (router, stash) can surface the state of the flip on a
   per-pid basis (parity with the info tuples the sibling captures
   return — sensor probes can read "did we install quirks for this
   pid" without a lock probe).
3. Attribute-name constants live inside the enum as
   `AXQuirksInstaller.manualAccessibility` /
   `AXQuirksInstaller.enhancedUserInterface`, mirroring
   `AXAttributeConstants.ManualAccessibility` /
   `AXAttributeConstants.EnhancedUserInterface`.
4. CFBoolean handling: Swift can bridge Bool to CFBoolean via
   `kCFBooleanTrue` / `kCFBooleanFalse`, or (equivalently) cast
   `NSNumber(value: value)` — but per Everywhere's L1181-1184 comment
   the ONLY safe path is the CFBoolean singleton. Use `kCFBooleanTrue`
   / `kCFBooleanFalse` explicitly.
5. Error model: task spec says throw `AXQuirksError.setAttributeFailed`
   on non-success / non-noValue AXError. This is a deliberate deviation
   from Everywhere (which returns bool). Preserving Everywhere's
   "success = success only" semantic would make `installIfNeeded`
   throw on the first-time flip for some apps because the private
   attributes can return `.failure` while still taking effect. The
   task spec's `.success || .noValue` widening handles that.
6. Idempotency: track installed pids in a `Set<Int32>` guarded by an
   `NSLock`. On second call for the same pid: return without doing
   any work. Failed installs are NOT cached — an install that threw is
   allowed to be retried (matches "best-effort" semantic).

## Deviations from Everywhere (documented in the file header)

| # | Everywhere | openclicky port | Rationale |
|---|-----------|-----------------|-----------|
| 1 | Returns `bool` on failure | Throws `AXQuirksError.setAttributeFailed` | Task spec HARD constraint |
| 2 | `AXError.Success` only | `.success` or `.noValue` allowed | Private attrs return `.noValue` when the app doesn't advertise them; still counts as "the flip landed" |
| 3 | `manualOk || enhancedOk` (partial success ok) | Both must succeed; first failure throws | Simpler contract for callers — a partial-success cache would be misleading. Cache is only populated after both attributes land. |
| 4 | Timeout wrapper at caller (AppResolver 1500ms) | Not in installer; caller responsibility | Same separation Everywhere uses |
| 5 | `ConcurrentDictionary<int,bool>` | `Set<Int32>` + `NSLock` | Same guarantees, Swift-idiomatic |

## Tests

- `installIfNeeded_forOwnPid_doesNotThrow` — the test process is a
  well-behaved AX-capable process. Some CI environments may not have
  Accessibility consent granted; in that case the call still returns
  the AXError which we translate into `AXQuirksError.setAttributeFailed`.
  Tests treat "consent-denied" as an expected outcome (skip / soft
  assert) so `swift test` remains green on a fresh checkout.
- `installIfNeeded_isIdempotent` — second call must be a no-op even if
  the first call errored. This is verified without side-effects: we
  snapshot the installed-set count before/after.
- `setBoolAttribute_invalidPid_throws` — pid `0` and negative pids.
- `setBoolAttribute_unknownAttribute_doesNotCrash` — an unknown
  attribute name is allowed to error, but must NOT trap.

## Files touched

- Add: `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Capture/AXQuirksInstaller.swift`
- Add: `Packages/OpenClickyContextService/Tests/OpenClickyContextServiceTests/AXQuirksInstallerTests.swift`
- Append `AXQuirkInfo` + `AXQuirksError` to:
  `Packages/OpenClickyContextService/Sources/OpenClickyContextService/Types/CaptureTypes.swift`
