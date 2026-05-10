# Menu Bar Status Icon

## Problem

The menu bar icon is static (`externaldrive.badge.wifi`) regardless of mount state. Users have no way to know if their drives are connected without clicking the popover.

## Solution

Update the menu bar icon to reflect current mount status using three SF Symbols.

## Status States

| Status | Condition | SF Symbol |
|--------|-----------|-----------|
| All connected | All servers with matching auto-mount rules are mounted | `externaldrive.fill.badge.checkmark` |
| Idle | No servers configured, or no rules match current network | `externaldrive.badge.wifi` |
| Has failures | At least one server that should be mounted is not | `externaldrive.badge.exclamationmark` |

## Status Calculation

```
let matchingServers = servers with auto-mount rules matching current fingerprint
if matchingServers is empty → idle
else if all matchingServers have existing mount paths → allConnected
else → hasFailed
```

Uses `MountingManager.shared.findExistingMountPath(for:)` which is lightweight (reads `FileManager.mountedVolumeURLs`).

## Update Trigger

A Combine `Timer` polling every 10 seconds. Simpler than subscribing to multiple event sources, and `findExistingMountPath` is cheap enough to call at this frequency.

## File Changes

| File | Change |
|------|--------|
| `ViewModels/AppState.swift` | Add `MountStatus` enum and `computeMountStatus(fingerprint:)` method |
| `AppDelegate.swift` | Add 10-second timer that updates `statusItem.button.image` based on status |

## Design Decisions

### Why polling instead of event-driven?

Mount state can change from many sources (AutoMountService, SleepWakeManager, Finder, external tools). Subscribing to all of them is fragile and creates coupling. Polling every 10 seconds is simple, reliable, and has negligible overhead.

### Why computed per-call instead of @Published?

The status depends on both `AppState.servers` and live filesystem state (`findExistingMountPath`). A computed method called by the timer is simpler than maintaining a reactive pipeline that tracks both.
