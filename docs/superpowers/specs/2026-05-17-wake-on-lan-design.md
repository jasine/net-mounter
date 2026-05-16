# Wake-on-LAN Feature Design

## Overview

Add Wake-on-LAN (WOL) support to NetMounter so that when a user opens their laptop (or the network changes), the app automatically wakes a sleeping NAS before attempting to mount its shares. WOL is a per-server optional feature that integrates into the existing auto-mount pipeline.

## Context

- **Target users**: NAS owners who put their NAS to sleep to save power and want it to wake automatically when they arrive home.
- **Competitors**: AutoMounter (WOL embedded in rule engine), ConnectMeNow (per-share WOL toggle + MAC/broadcast/port config + delay).
- **Design choice**: Per-server WOL toggle integrated into AutoMountService's `attemptMount` flow (Approach A). WOL is a best-effort pre-mount step — failures gracefully fall back to existing retry logic.

## Data Model Changes

### ServerConfig additions

```swift
struct ServerConfig: Codable, Identifiable {
    // ... existing fields ...

    // WOL configuration
    var wolEnabled: Bool = false
    var wolMACAddress: String?       // "AA:BB:CC:DD:EE:FF", auto-detected
    var wolBroadcastAddress: String? // nil = default 255.255.255.255
    var wolPort: UInt16 = 9          // standard WOL port
}
```

- `wolEnabled`: user-facing toggle, only activatable when `wolMACAddress` is non-nil.
- `wolMACAddress`: auto-learned from ARP table when the server is reachable. Editable in UI as fallback.
- `wolBroadcastAddress` and `wolPort`: advanced settings, hidden under a disclosure group. Defaults work for 99% of home networks.

## New Service: WOLService

File: `Sources/NetMounter/Services/WOLService.swift`

Stateless utility class. Two responsibilities:

### 1. Send Magic Packet

```swift
func wake(macAddress: String,
          broadcastAddress: String = "255.255.255.255",
          port: UInt16 = 9) throws
```

- Constructs a 102-byte magic packet: 6 bytes `0xFF` followed by the target MAC address repeated 16 times.
- Sends via `NWConnection` UDP datagram to the broadcast address.
- No root privileges required — standard UDP broadcast works in macOS user-space.
- Throws on invalid MAC format or send failure.

### 2. Resolve MAC Address

```swift
func resolveMAC(for hostname: String) -> String?
```

- Runs `arp -n <hostname>` and parses the MAC address from the output.
- Returns `nil` if the host is not in the ARP table (device offline or not on local network).
- Reuses the `runCommand` pattern from `NetworkMonitor`.

## AutoMountService Integration

### Modified Flow in `attemptMount`

Current flow:
```
checkReachability → reachable → mount
                  → unreachable → scheduleRetry
```

New flow:
```
checkReachability
  → reachable → mount (unchanged)
  → unreachable
      → wolEnabled == false → scheduleRetry (unchanged)
      → wolEnabled == true
          → deduplicate by hostname (skip if already polling)
          → WOLService.wake(mac, broadcast, port)
          → poll: checkReachability every 3s, timeout 60s
              → reachable → mount
              → timeout → scheduleRetry (normal retry count)
```

### Hostname Deduplication

`AutoMountService` maintains a `private var wolPendingServers: [String: [ServerConfig]]` dictionary keyed by hostname. When the first share for a hostname enters WOL polling, it sends the magic packet and starts the poll timer. Subsequent shares targeting the same hostname are appended to the array and skip WOL sending. When polling succeeds (host becomes reachable), all queued shares proceed to mount. When polling times out, all queued shares enter `scheduleRetry`.

The dictionary is cleared for a hostname when its poll completes (success or timeout), and entirely cleared in `cancelAllRetries()` (called on network change).

### WOL Trigger Constraint

WOL is only attempted when `retryCount == 0` (the first attempt). Subsequent retries follow the existing exponential backoff without re-sending WOL packets. This prevents flooding the network with magic packets during retry loops.

### Trigger Coverage

All three selected trigger scenarios flow through `attemptMount` naturally:

1. **Lid open (wake from sleep)**: `SleepWakeManager.handleDidWake` → `autoMountService.evaluateAutoMount` → `attemptMount` → WOL
2. **Network change**: `NetworkMonitor.currentFingerprint` change → `AutoMountService.setupBindings` sink → `evaluateAutoMount` → `attemptMount` → WOL
3. **Health check**: `performPeriodicHealthCheck` → `attemptMount` (retryCount: 0) → WOL

No changes needed to SleepWakeManager or NetworkMonitor.

## MAC Auto-Learning

### Learning Points

1. **After successful mount** (in `attemptMount` success callback): if `wolMACAddress == nil`, call `WOLService.resolveMAC(for: hostname)` on a background queue. If non-nil, update `ServerConfig` and persist.
2. **After successful Test Connection** (in `ServerDetailView.testConnection`): same logic — resolve and backfill.

### Behavior

- Silent — no notification or prompt to the user.
- MAC is stored permanently. If it becomes stale (e.g., NAS NIC replacement), the user can manually edit it in the server detail view.
- If ARP resolution fails (returns nil), `wolMACAddress` stays nil and the WOL toggle remains disabled.

## UI Changes

### ServerDetailView — New Section

Add a "Wake-on-LAN" section in the server edit form, positioned after the Auto-Mount toggle:

```
Section: Wake-on-LAN
  ├─ Toggle: "Wake before mount"
  │   ├─ Bound to wolEnabled
  │   └─ Disabled with caption "Connect to server once to detect MAC address"
  │      when wolMACAddress == nil
  ├─ TextField: "MAC Address" (displays wolMACAddress, editable)
  └─ DisclosureGroup: "Advanced"
       ├─ TextField: "Broadcast Address" (default "255.255.255.255")
       └─ TextField: "Port" (default "9")
```

### No Menu Bar Changes

WOL is invisible in the menu bar / server list. It operates as an internal pre-mount step. The user's experience is simply: "I opened my laptop and my NAS shares appeared."

## Notifications

Reuse existing `NotificationService`:

| Event | Notification |
|---|---|
| WOL sent | None (silent) |
| WOL + mount succeeded | Existing `notifyMountSucceeded` |
| WOL poll timeout (60s, host never became reachable) | New: `notifyWOLFailed(server:)` — "Could not wake {alias}. Check if WOL is enabled on the device." |

## Error Handling

| Scenario | Handling |
|---|---|
| Invalid MAC address format | `WOLService.wake()` throws; caller logs warning, skips WOL, falls through to `scheduleRetry` |
| UDP send failure | Same as above — WOL failure never blocks mount retry |
| ARP resolution failure | `resolveMAC` returns nil; `wolMACAddress` stays nil; WOL toggle stays disabled |
| WOL poll timeout (60s) | Enter normal `scheduleRetry` with current retry count |
| Concurrent WOL for same hostname | Dedup set ensures only one magic packet + poll; other shares queue and mount after poll succeeds |

**Core principle**: WOL is best-effort. Any WOL failure gracefully falls back to existing behavior. The auto-mount pipeline must never break due to WOL issues.

## Testing Strategy

### Unit Tests

- `WOLService`: magic packet construction (verify 102-byte format, correct MAC encoding)
- `WOLService`: MAC address validation (accept `AA:BB:CC:DD:EE:FF` and `AA-BB-CC-DD-EE-FF`, reject invalid)
- `ServerConfig`: `wolEnabled` only effective when `wolMACAddress` is non-nil

### Integration Tests

- `AutoMountService`: verify WOL branch is entered when server is unreachable and `wolEnabled == true`
- `AutoMountService`: verify hostname deduplication (mock two shares, same host — only one WOL call)
- `AutoMountService`: verify WOL is not retried on `retryCount > 0`

### Manual Testing

- Configure a real NAS with WOL enabled, verify end-to-end wake + mount after lid open
- Verify MAC auto-detection populates correctly after first successful connection
- Verify the UI toggle is disabled when MAC is not yet detected

## Files Changed

| File | Change |
|---|---|
| `Models/ServerConfig.swift` | Add WOL fields (wolEnabled, wolMACAddress, wolBroadcastAddress, wolPort) |
| `Services/WOLService.swift` | **New file** — magic packet send + MAC resolution |
| `Services/AutoMountService.swift` | Add WOL branch in `attemptMount`, hostname dedup set, poll loop |
| `Services/NotificationService.swift` | Add `notifyWOLFailed(server:)` |
| `Views/ServerDetailView.swift` | Add Wake-on-LAN section in form |
