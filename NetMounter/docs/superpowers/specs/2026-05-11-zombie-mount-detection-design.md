# Zombie Mount Detection & Self-Healing

## Problem

When a network mount becomes unresponsive (zombie), the current `AutoMountService.performPeriodicHealthCheck()` doesn't detect it — `findExistingMountPath` still finds the volume (it appears in the filesystem), so the health check logs "already mounted" and moves on. Meanwhile, Finder hangs when accessing the zombie mount.

## Solution

Add an aliveness check (`isMountAlive`) after finding an existing mount path in the periodic health check. If the mount is unresponsive (times out after 2 seconds), force-unmount it and trigger a remount.

## Changes

### AutoMountService.performPeriodicHealthCheck()

Current (broken) logic:
```
if findExistingMountPath returns path → log "mounted" → skip
if returns nil → log "not mounted" → attemptMount
```

Fixed logic:
```
if findExistingMountPath returns path:
    if isMountAlive(path) → truly alive → skip
    else → zombie → forceUnmount(path) → attemptMount
if returns nil → not mounted → attemptMount
```

### MountingManager visibility changes

- `isMountAlive(_:) -> Bool` — change from `private` to `internal`
- `forceUnmount(path:)` — change from `private` to `internal`

These methods already exist and are well-implemented (2-second timeout on `isMountAlive`, `diskutil unmount force` on `forceUnmount`).

## File Changes

| File | Change |
|------|--------|
| `Services/MountingManager.swift` | Change `isMountAlive` and `forceUnmount` from `private` to `internal` |
| `Services/AutoMountService.swift` | Add zombie detection branch in `performPeriodicHealthCheck()` (~10 lines) |

## Detection Behavior

- **Interval:** Every 5 minutes (existing timer, unchanged)
- **Timeout:** 2 seconds per mount aliveness check (existing `isMountAlive` implementation)
- **Action on zombie:** Force unmount → attempt remount (with existing retry logic)
- **Scope:** Only servers with matching auto-mount rules for the current network

## Design Decisions

### Why 5-minute interval is acceptable

- The sleep/wake feature (already implemented) proactively prevents most zombies by unmounting before sleep
- Zombies during normal operation (network blip mid-session) are rarer
- More frequent polling would add I/O load for marginal benefit
- 5 minutes is the worst-case detection latency — acceptable for a background recovery

### Why only managed servers

- Manual mounts have no credentials stored in NetMounter — can't remount them
- Force-unmounting a user's manual mount without their knowledge could be surprising
- For manual mounts, the sleep/wake snapshot-and-restore already provides best-effort recovery
