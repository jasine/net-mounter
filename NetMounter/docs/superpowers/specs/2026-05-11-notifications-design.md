# Mount Notifications

## Problem

Users have no way to know when mounts fail or recover unless they actively check the popover. Background events (auto-mount failures, zombie recovery, wake reconnection) happen silently.

## Solution

A `NotificationService` that sends macOS notifications via `UNUserNotificationCenter` for key mount lifecycle events. Failure notifications include a "Retry" action button.

## Notification Events

| Event | Title | Body | Action |
|-------|-------|------|--------|
| Auto-mount retry exhausted | "Mount Failed" | "{alias} failed after 5 retries" | "Retry" button |
| Zombie detected and healed | "Connection Restored" | "{alias} recovered from unresponsive state" | None |
| Wake reconnect succeeded | "Connections Restored" | "Restored {count} network drive(s) after wake" | None |
| Wake reconnect failed (timeout) | "Reconnect Failed" | "{count} drive(s) not restored after wake" | "Retry" button |

## Architecture

### NotificationService

A singleton that:
1. Registers notification categories and actions with `UNUserNotificationCenter`
2. Provides typed methods for each event (`notifyMountFailed(server:)`, `notifyZombieHealed(server:)`, etc.)
3. Implements `UNUserNotificationCenterDelegate` to handle "Retry" action — looks up server by ID from notification's `userInfo` and calls `AutoMountService.attemptMount`

### Integration Points

- `AutoMountService.scheduleRetry` — when `currentRetryCount >= maxRetries`, call `NotificationService.shared.notifyMountFailed(server:)`
- `AutoMountService.performPeriodicHealthCheck` — after zombie force-unmount + remount, call `NotificationService.shared.notifyZombieHealed(server:)`
- `SleepWakeManager.handleNetworkReady` — after restoring mounts, call `NotificationService.shared.notifyWakeReconnected(count:)`
- `SleepWakeManager.cancelWakeWait` (timeout path) — call `NotificationService.shared.notifyWakeReconnectFailed(count:)`

### Permission Request

In `AppDelegate.applicationDidFinishLaunching`, call `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])`. macOS shows system permission dialog on first launch.

## File Changes

| File | Change |
|------|--------|
| `Services/NotificationService.swift` | **New**, ~80 lines |
| `AppDelegate.swift` | Initialize NotificationService, request notification permission |
| `Services/AutoMountService.swift` | Add notification calls at retry exhaustion and zombie heal (~4 lines) |
| `Services/SleepWakeManager.swift` | Add notification calls at wake success and timeout (~4 lines) |

## Design Decisions

### Why UNUserNotificationCenter over NSUserNotification?

`NSUserNotification` is deprecated since macOS 11. `UNUserNotificationCenter` supports action buttons, categories, and is the modern standard.

### Why a separate NotificationService instead of inline calls?

Centralizes notification category registration, delegate handling, and retry-action logic. Callers just call one method — no notification boilerplate scattered across services.
