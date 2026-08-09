# RunningAppsCapture — port investigation (2026-07-23)

## Everywhere ground truth

`src/Everywhere.Mac/Interop/VisualElementContext.cs` @30e03e9dcfdd4247fd679828ed86e9042f32d809, L97-111:

```csharp
public IReadOnlyList<(IVisualElement Window, int ProcessId)> TryFastListApps()
{
    var apps = NSWorkspace.SharedWorkspace.RunningApplications;
    var result = new List<(IVisualElement, int)>(apps.Length);
    foreach (var app in apps)
    {
        if (app.ActivationPolicy == NSApplicationActivationPolicy.Prohibited) continue;
        var pid = app.ProcessIdentifier;
        if (pid <= 0) continue;
        var win = AXUIElement.FreshFocusedWindowOf(pid);
        if (win is null) continue;
        result.Add((win, pid));
    }
    return result;
}
```

Companion `TryFastResolveByName` (L79-95) uses the same iteration order and the
same `ActivationPolicy != Prohibited` gate — no other filtering.

Consumer: `Everywhere.Mcp/Tools/ListAppsTool.cs` + `AppResolver.cs:162`
(`context.TryFastListApps()`). The MCP tool description sells it as "every
running app with at least one top-level window — including menubar-only apps
like Bartender/Typeless" — i.e. the `FreshFocusedWindowOf` gate is what turns
this into a windowed-apps list rather than a raw process list.

## Filter rules to reproduce

1. Iterate `NSWorkspace.shared.runningApplications` in the order AppKit returns
   them. Everywhere makes no re-sort — order is whatever AppKit gives.
2. Skip entries where `activationPolicy == .prohibited`.
3. Skip entries with `processIdentifier <= 0`.
4. Everywhere additionally skips entries whose `AXUIElement.FreshFocusedWindowOf(pid)`
   returns `nil` (i.e. "the app owns no addressable AX window right now").

## Deviation for the port

Rule 4 requires an AX round-trip per process. That belongs in a separate layer
(`FocusedWindowCapture` already ports `FreshFocusedWindowOf`). This capture is
positioned upstream of any AX work — the roadmap describes it as "windows+pid
list" but Everywhere's own `NSWorkspace` snapshot is process-level, and the
FreshFocusedWindowOf gate is really a "does it have a window" filter tacked on.

Plan: port rules 1-3 verbatim here, expose the AX-window filter through the
`FocusedWindowCapture` pipeline the caller already has. RunningAppInfo carries
enough fields (`activationPolicy`, `isHidden`, `ownsMenuBar`, etc.) for the
caller to reproduce Everywhere's exact behaviour post-hoc if they need to.

Document this in the file header + `.impl-notes` audit.

## Ordering

`NSWorkspace.shared.runningApplications` is documented as "The array of running
applications" with no stated order. Empirically on macOS 14+ the order is
stable across quick successive calls (backed by an ordered internal LSApplicationRef
map) but a new launch / termination between calls will reorder things. We
document the ordering as "as AppKit returns them; do not depend on stability
across app-launch events" and add a smoke test that asserts stability across
two back-to-back reads.

## Fields to populate (matches task brief)

| Field                | Source                                         |
|----------------------|------------------------------------------------|
| `processId`          | `NSRunningApplication.processIdentifier`       |
| `bundleId`           | `NSRunningApplication.bundleIdentifier`        |
| `name`               | `NSRunningApplication.localizedName`           |
| `executableName`     | `executableURL?.lastPathComponent`             |
| `activationPolicy`   | `FrontmostActivationPolicy(app.activationPolicy)` (reuse existing enum) |
| `isHidden`           | `NSRunningApplication.isHidden`                |
| `isFinishedLaunching`| `NSRunningApplication.isFinishedLaunching`     |
| `ownsMenuBar`        | `NSRunningApplication.ownsMenuBar`             |
| `launchDate`         | `NSRunningApplication.launchDate`              |

Everywhere does not read most of these — we surface them because openclicky's
downstream stash wants a richer view than Everywhere's `(Window, ProcessId)`
tuple. They are Codable-safe and cheap.

## Public API

```swift
public enum RunningAppsCapture {
    public static func list() -> [RunningAppInfo]
}
```

Single sync function. Everywhere's `TryFastListApps` is sync too.

## Test plan

- `list()` returns non-empty on any live Mac (also covers this test process).
- Every entry has `processId > 0` and `activationPolicy != .prohibited`.
- Order is stable across two consecutive reads within a few ms (best-effort;
  documented as unspecified across launch/exit events).
- JSON round-trip on a hand-built `RunningAppInfo`.
- Optional UI-gated: when Finder is up, it appears in the list.
