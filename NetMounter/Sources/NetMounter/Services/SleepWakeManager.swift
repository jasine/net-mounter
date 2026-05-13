// Sources/NetMounter/Services/SleepWakeManager.swift
import Foundation
import Combine
import AppKit
import NetFS
import Logging

private let logger = Logger(label: "SleepWake")

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
            let count = self.sleepSnapshot.count
            self.cancelWakeWait()
            if count > 0 {
                NotificationService.shared.notifyWakeReconnectFailed(count: count)
            }
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
                logger.info("Restored manual mount: \(snapshot.volumePath)")
            } else {
                logger.debug("Could not restore manual mount \(snapshot.volumePath) (error \(result))")
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

    // MARK: - Unmount Helpers

    private func unmountWithTimeout(path: String, timeout: TimeInterval, completion: @escaping () -> Void) {
        var completed = false
        let lock = NSLock()

        MountingManager.shared.unmount(mountPath: path) { error in
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()

            if let error = error {
                logger.warning("Graceful unmount failed for \(path): \(error.localizedDescription)")
                self.forceUnmount(path: path)
            } else {
                logger.info("Gracefully unmounted \(path)")
            }
            completion()
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()

            logger.warning("Unmount timed out for \(path) — force unmounting")
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

    deinit {
        cancelWakeWait()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
