# Sleep/Wake Reconnect & Graceful Disconnect

## Problem

macOS network mounts break when a Mac sleeps and wakes. Mounts either become zombies (appear connected but hang Finder) or silently disappear. Users must manually remount every time they open their laptop. This is the highest-frequency pain point for any network mount tool user.

## Solution

A new `SleepWakeManager` service that:
1. **Before sleep:** captures a snapshot of mounted network volumes, then gracefully unmounts them all (preventing zombies).
2. **After wake:** waits for the network to become available, then restores mounts — both auto-mount rule servers and manually-mounted volumes.

## Architecture

### New Components

**`SleepWakeManager`** — a service initialized in `AppDelegate`, subscribing to `NSWorkspace` sleep/wake notifications. Coordinates `MountingManager`, `NetworkMonitor`, and `AutoMountService`.

**`MountSnapshot`** — a lightweight struct capturing each mounted network volume at sleep time:

```swift
struct MountSnapshot {
    let serverID: UUID?       // matches ServerConfig; nil for manual mounts
    let volumePath: String    // e.g. "/Volumes/shared"
    let remountURL: URL       // from volumeURLForRemounting resource key
}
```

### Sleep Flow (willSleepNotification)

1. Scan `/Volumes` via `FileManager.mountedVolumeURLs` with `volumeURLForRemounting` resource key to identify network volumes.
2. Match each volume against `AppState.servers` by comparing remount URL host/path. Matched volumes get a `serverID`; unmatched ones are recorded with `serverID = nil`.
3. Store the list as `sleepSnapshot`.
4. Unmount all volumes in parallel using `DispatchGroup`:
   - Graceful unmount via `diskutil unmount` with 3-second per-volume timeout.
   - Volumes that fail graceful unmount get `diskutil unmount force`.
   - Overall timeout: 5 seconds. System sleep cannot be delayed indefinitely.

### Wake Flow (didWakeNotification)

1. Set `isAwaitingReconnect = true`.
2. Subscribe to `NetworkMonitor.currentFingerprint` changes.
3. When fingerprint becomes non-nil (network is ready), proceed with reconnection.
4. Safety timeout: 30 seconds. If network never recovers, abandon reconnect attempt.

Reconnection has two paths:

- **Managed servers (serverID != nil):** Delegate to `AutoMountService.evaluateAutoMount(for: fingerprint)`. This already handles connectivity checks, retries, and rule matching. No new logic needed.
- **Manual mounts (serverID == nil):** Attempt `NetFSMountURLSync` with the snapshot's `remountURL`. No retries — best-effort only.

### Network Change After Sleep

If the user sleeps at office and wakes at home:
- Managed servers: `evaluateAutoMount` uses the new fingerprint to match rules. Office servers won't match; home servers will. Correct by design.
- Manual mounts: reconnect attempt fails quickly (server unreachable). Acceptable.

## File Changes

| File | Change |
|------|--------|
| `Services/SleepWakeManager.swift` | **New file**, ~120 lines |
| `AppDelegate.swift` | Add `sleepWakeManager` property + 1 line initialization |
| `Services/MountingManager.swift` | Add public `getAllNetworkMounts() -> [MountSnapshot]` method |

### Files NOT changed

- `AutoMountService.swift` — wake triggers fingerprint change, which already triggers `evaluateAutoMount`.
- `NetworkMonitor.swift` — existing fingerprint publishing is sufficient.
- Data models — no schema changes needed.

## Integration

In `AppDelegate.applicationDidFinishLaunching`:

```swift
appState = AppState()
autoMountService = AutoMountService(appState: appState)
sleepWakeManager = SleepWakeManager(
    appState: appState,
    networkMonitor: .shared,
    autoMountService: autoMountService
)
```

One new line. No changes to existing initialization flow.

## Design Decisions

### Why unmount before sleep instead of just reconnecting after?

Not unmounting leaves zombie mounts that hang Finder on wake. The cost of unmounting (volumes briefly disappear) is far lower than the cost of zombies (Finder hangs, force-quit needed). Reconnection completes within seconds of wake, making the disappearance nearly imperceptible.

### Why snapshot instead of just re-running auto-mount on wake?

Users may have manually mounted volumes not covered by auto-mount rules. The snapshot captures all network mounts, allowing best-effort restoration of manual mounts too.

### Why a separate SleepWakeManager instead of adding to AppDelegate or AutoMountService?

- `AppDelegate` should stay focused on UI setup.
- `AutoMountService` handles network-change-based mounting; sleep/wake is a distinct lifecycle concern with its own state (snapshot, awaiting-reconnect flag, timeouts).
- A dedicated service is easier to reason about and test.

## Timeouts

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Per-volume graceful unmount | 3s | Enough for responsive volumes; unresponsive ones get force-unmounted |
| Overall sleep unmount | 5s | System sleep should not be delayed significantly |
| Wake network wait | 30s | WiFi association is usually 1-3s; 30s covers edge cases without hanging |
