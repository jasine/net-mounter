# Sleep/Wake Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically unmount network drives before Mac sleep and remount them after wake, eliminating zombie mounts and manual reconnection.

**Architecture:** A new `SleepWakeManager` service listens for `NSWorkspace` sleep/wake notifications. Before sleep, it snapshots all mounted network volumes and gracefully unmounts them. After wake, it waits for `NetworkMonitor` to report a valid fingerprint, then delegates reconnection to `AutoMountService` (for managed servers) and attempts direct `NetFSMountURLSync` (for manual mounts).

**Tech Stack:** Swift 5.10, macOS 14+, NetFS framework, NSWorkspace notifications, Combine

---

## File Structure

| File | Responsibility |
|------|---------------|
| `Sources/NetMounter/Models/MountSnapshot.swift` | **New.** Data model for a point-in-time record of a mounted network volume |
| `Sources/NetMounter/Services/MountingManager.swift` | **Modify.** Add `getAllNetworkMounts(matching:)` public method to scan `/Volumes` |
| `Sources/NetMounter/Services/SleepWakeManager.swift` | **New.** Core service: subscribe to sleep/wake, coordinate unmount and remount |
| `Sources/NetMounter/AppDelegate.swift` | **Modify.** Add `sleepWakeManager` property and initialize it |
| `Tests/NetMounterTests/MountSnapshotTests.swift` | **New.** Tests for snapshot-to-ServerConfig matching logic |

---

### Task 1: MountSnapshot Model

**Files:**
- Create: `Sources/NetMounter/Models/MountSnapshot.swift`
- Test: `Tests/NetMounterTests/MountSnapshotTests.swift`

- [ ] **Step 1: Write the failing test for MountSnapshot matching**

```swift
// Tests/NetMounterTests/MountSnapshotTests.swift
import XCTest
@testable import NetMounter

final class MountSnapshotTests: XCTestCase {

    func testMatchesServerConfig_sameHostAndShare() {
        let snapshot = MountSnapshot(
            serverID: nil,
            volumePath: "/Volumes/shared",
            remountURL: URL(string: "smb://192.168.1.100/shared")!
        )
        let config = ServerConfig(
            alias: "NAS",
            serverProtocol: .smb,
            hostname: "192.168.1.100",
            sharePath: "shared"
        )
        XCTAssertTrue(snapshot.matches(config))
    }

    func testMatchesServerConfig_differentHost() {
        let snapshot = MountSnapshot(
            serverID: nil,
            volumePath: "/Volumes/shared",
            remountURL: URL(string: "smb://10.0.0.5/shared")!
        )
        let config = ServerConfig(
            alias: "NAS",
            serverProtocol: .smb,
            hostname: "192.168.1.100",
            sharePath: "shared"
        )
        XCTAssertFalse(snapshot.matches(config))
    }

    func testMatchesServerConfig_caseInsensitiveHost() {
        let snapshot = MountSnapshot(
            serverID: nil,
            volumePath: "/Volumes/docs",
            remountURL: URL(string: "smb://MyNAS.local/docs")!
        )
        let config = ServerConfig(
            alias: "NAS",
            serverProtocol: .smb,
            hostname: "mynas.local",
            sharePath: "docs"
        )
        XCTAssertTrue(snapshot.matches(config))
    }

    func testMatchesServerConfig_differentShare() {
        let snapshot = MountSnapshot(
            serverID: nil,
            volumePath: "/Volumes/photos",
            remountURL: URL(string: "smb://192.168.1.100/photos")!
        )
        let config = ServerConfig(
            alias: "NAS",
            serverProtocol: .smb,
            hostname: "192.168.1.100",
            sharePath: "documents"
        )
        XCTAssertFalse(snapshot.matches(config))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift test --filter MountSnapshotTests 2>&1`

Expected: Compilation error — `MountSnapshot` not defined.

- [ ] **Step 3: Write MountSnapshot implementation**

```swift
// Sources/NetMounter/Models/MountSnapshot.swift
import Foundation

struct MountSnapshot {
    let serverID: UUID?
    let volumePath: String
    let remountURL: URL

    func matches(_ config: ServerConfig) -> Bool {
        guard let snapshotHost = remountURL.host?.lowercased(),
              let snapshotShare = remountURL.pathComponents.last else {
            return false
        }
        let configHost = config.hostname.lowercased()
        let configShare = config.sharePath.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        return snapshotHost == configHost && snapshotShare == configShare
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift test --filter MountSnapshotTests 2>&1`

Expected: All 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/NetMounter/Models/MountSnapshot.swift Tests/NetMounterTests/MountSnapshotTests.swift
git commit -m "feat: add MountSnapshot model with server matching"
```

---

### Task 2: MountingManager.getAllNetworkMounts

**Files:**
- Modify: `Sources/NetMounter/Services/MountingManager.swift`

This method scans `/Volumes` for network volumes and returns `[MountSnapshot]`, matching each against the provided `[ServerConfig]`. This uses the same `volumeURLForRemounting` technique already used in `findExistingMountPath`.

Note: This method interacts directly with the filesystem (`FileManager.mountedVolumeURLs`), so it cannot be unit-tested without real mounts. The matching logic is already tested via `MountSnapshot.matches` in Task 1.

- [ ] **Step 1: Add `getAllNetworkMounts` to MountingManager**

Add the following method to `MountingManager` in `Services/MountingManager.swift`, after the existing `findExistingMountPath` method (after line 118):

```swift
    func getAllNetworkMounts(matching servers: [ServerConfig]) -> [MountSnapshot] {
        let keys: [URLResourceKey] = [.volumeURLForRemountingKey, .volumeIsLocalKey]
        guard let mountedURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: []
        ) else { return [] }

        var snapshots: [MountSnapshot] = []

        for mountURL in mountedURLs {
            guard let values = try? mountURL.resourceValues(forKeys: Set(keys)) else { continue }

            // Skip local volumes
            if values.volumeIsLocal == true { continue }

            guard let remountURL = values.volumeURLForRemounting else { continue }

            let snapshot = MountSnapshot(
                serverID: nil,
                volumePath: mountURL.path,
                remountURL: remountURL
            )

            // Try to match against known server configs
            let matchedServer = servers.first { snapshot.matches($0) }
            let finalSnapshot = MountSnapshot(
                serverID: matchedServer?.id,
                volumePath: mountURL.path,
                remountURL: remountURL
            )
            snapshots.append(finalSnapshot)
        }

        return snapshots
    }
```

- [ ] **Step 2: Verify build compiles**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift build 2>&1`

Expected: Build succeeds.

- [ ] **Step 3: Run existing tests to verify no regressions**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift test 2>&1`

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/NetMounter/Services/MountingManager.swift
git commit -m "feat: add getAllNetworkMounts to scan mounted network volumes"
```

---

### Task 3: SleepWakeManager — Sleep Flow

**Files:**
- Create: `Sources/NetMounter/Services/SleepWakeManager.swift`

- [ ] **Step 1: Create SleepWakeManager with sleep flow**

```swift
// Sources/NetMounter/Services/SleepWakeManager.swift
import Foundation
import Combine
import NetFS
import os

private let logger = Logger(subsystem: "com.netmounter.app", category: "SleepWake")

class SleepWakeManager {
    private let appState: AppState
    private let networkMonitor: NetworkMonitor
    private let autoMountService: AutoMountService

    private var sleepSnapshot: [MountSnapshot] = []
    private var isAwaitingReconnect = false
    private var wakeCancellable: AnyCancellable?
    private var wakeTimeoutWork: DispatchWorkItem?

    init(appState: AppState, networkMonitor: NetworkMonitor, autoMountService: AutoMountService) {
        self.appState = appState
        self.networkMonitor = networkMonitor
        self.autoMountService = autoMountService
        subscribeToSleepWake()
    }

    private func subscribeToSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(handleWillSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(handleDidWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: - Sleep

    @objc private func handleWillSleep(_ notification: Notification) {
        logger.info("System will sleep — snapshotting and unmounting network volumes")

        sleepSnapshot = MountingManager.shared.getAllNetworkMounts(matching: appState.servers)
        logger.info("Snapshot captured: \(self.sleepSnapshot.count) network volume(s)")

        guard !sleepSnapshot.isEmpty else { return }

        let group = DispatchGroup()
        let perVolumeTimeout: TimeInterval = 3.0

        for snapshot in sleepSnapshot {
            group.enter()
            unmountWithTimeout(path: snapshot.volumePath, timeout: perVolumeTimeout) {
                group.leave()
            }
        }

        // Block until all unmounts finish or 5s overall timeout
        let result = group.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            logger.warning("Overall unmount timeout — force unmounting remaining volumes")
            for snapshot in sleepSnapshot {
                forceUnmount(path: snapshot.volumePath)
            }
        }

        logger.info("Sleep preparation complete")
    }

    private func unmountWithTimeout(path: String, timeout: TimeInterval, completion: @escaping () -> Void) {
        var completed = false
        let lock = NSLock()

        MountingManager.shared.unmount(mountPath: path) { error in
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()

            if let error = error {
                logger.warning("Graceful unmount failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.forceUnmount(path: path)
            } else {
                logger.info("Gracefully unmounted \(path, privacy: .public)")
            }
            completion()
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()

            logger.warning("Unmount timed out for \(path, privacy: .public) — force unmounting")
            self.forceUnmount(path: path)
            completion()
        }
    }

    private func forceUnmount(path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", "force", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift build 2>&1`

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/NetMounter/Services/SleepWakeManager.swift
git commit -m "feat: add SleepWakeManager with sleep unmount flow"
```

---

### Task 4: SleepWakeManager — Wake Flow

**Files:**
- Modify: `Sources/NetMounter/Services/SleepWakeManager.swift`

- [ ] **Step 1: Add wake handling to SleepWakeManager**

Add the following methods to `SleepWakeManager`, after the `forceUnmount` method:

```swift
    // MARK: - Wake

    @objc private func handleDidWake(_ notification: Notification) {
        logger.info("System did wake — waiting for network")

        guard !sleepSnapshot.isEmpty else {
            logger.info("No snapshot to restore, skipping reconnect")
            return
        }

        isAwaitingReconnect = true

        // Watch for network to become available
        wakeCancellable = networkMonitor.$currentFingerprint
            .compactMap { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fingerprint in
                self?.handleNetworkReady(fingerprint: fingerprint)
            }

        // Safety timeout — don't wait forever
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self, self.isAwaitingReconnect else { return }
            logger.warning("Wake network timeout (30s) — abandoning reconnect")
            self.cancelWakeWait()
        }
        wakeTimeoutWork = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: timeoutWork)
    }

    private func handleNetworkReady(fingerprint: NetworkFingerprint) {
        logger.info("Network ready after wake — restoring mounts")
        cancelWakeWait()

        // Path 1: Managed servers — delegate to AutoMountService
        autoMountService.evaluateAutoMount(for: fingerprint)

        // Path 2: Manual mounts — best-effort remount via remountURL
        let manualMounts = sleepSnapshot.filter { $0.serverID == nil }
        for snapshot in manualMounts {
            remountManual(snapshot: snapshot)
        }

        sleepSnapshot = []
    }

    private func remountManual(snapshot: MountSnapshot) {
        DispatchQueue.global(qos: .utility).async {
            var mountpoints: Unmanaged<CFArray>?
            let result = NetFSMountURLSync(
                snapshot.remountURL as CFURL,
                nil, nil, nil, nil, nil,
                &mountpoints
            )
            if result == 0 {
                logger.info("Restored manual mount: \(snapshot.volumePath, privacy: .public)")
            } else {
                logger.debug("Could not restore manual mount \(snapshot.volumePath, privacy: .public) (error \(result))")
            }
        }
    }

    private func cancelWakeWait() {
        isAwaitingReconnect = false
        wakeCancellable?.cancel()
        wakeCancellable = nil
        wakeTimeoutWork?.cancel()
        wakeTimeoutWork = nil
    }

    deinit {
        cancelWakeWait()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
```

- [ ] **Step 2: Verify build compiles**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift build 2>&1`

Expected: Build succeeds.

- [ ] **Step 3: Run all tests**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift test 2>&1`

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/NetMounter/Services/SleepWakeManager.swift
git commit -m "feat: add wake reconnection flow to SleepWakeManager"
```

---

### Task 5: AppDelegate Integration

**Files:**
- Modify: `Sources/NetMounter/AppDelegate.swift`

- [ ] **Step 1: Add sleepWakeManager property and initialization**

In `AppDelegate.swift`, add a property after `autoMountService` (line 10):

```swift
    var sleepWakeManager: SleepWakeManager!
```

In `applicationDidFinishLaunching`, add one line after `autoMountService` initialization (after line 15):

```swift
        sleepWakeManager = SleepWakeManager(
            appState: appState,
            networkMonitor: .shared,
            autoMountService: autoMountService
        )
```

- [ ] **Step 2: Verify build compiles**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift build 2>&1`

Expected: Build succeeds.

- [ ] **Step 3: Run all tests**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift test 2>&1`

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/NetMounter/AppDelegate.swift
git commit -m "feat: wire SleepWakeManager into AppDelegate"
```

---

### Task 6: Manual Verification

**Files:** None — manual testing.

- [ ] **Step 1: Build and run the app**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift build 2>&1`

Open the built app or run it. Verify it launches and the menu bar icon appears.

- [ ] **Step 2: Verify sleep/wake behavior**

Manual test procedure:
1. Mount a network drive (via NetMounter or Finder)
2. Open Console.app, filter for `com.netmounter.app` subsystem and `SleepWake` category
3. Put Mac to sleep (Apple menu → Sleep, or close lid)
4. Wake the Mac
5. Verify in Console.app:
   - "System will sleep — snapshotting and unmounting" appears with correct volume count
   - "Gracefully unmounted" appears for each volume
   - "System did wake — waiting for network" appears
   - "Network ready after wake — restoring mounts" appears
   - Volumes reappear in Finder

- [ ] **Step 3: Verify no-mount sleep scenario**

1. Ensure no network drives are mounted
2. Sleep and wake the Mac
3. Verify in Console.app: "No snapshot to restore, skipping reconnect"
4. No errors in log
