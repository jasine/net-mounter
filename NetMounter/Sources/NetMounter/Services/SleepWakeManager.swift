// Sources/NetMounter/Services/SleepWakeManager.swift
import Foundation
import Combine
import AppKit
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

    // MARK: - Wake

    @objc private func handleDidWake(_ notification: Notification) {
        // Wake flow will be implemented in Task 4
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
