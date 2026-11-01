// Sources/NetMounter/Services/SleepWakeManager.swift
import Foundation
import Combine
import AppKit
import Logging

private let logger = Logger(label: "SleepWake")

class SleepWakeManager {
    private let appState: AppState
    private let networkMonitor: NetworkMonitor
    private let autoMountService: AutoMountService
    private let captureMounts: ([ServerConfig]) -> [MountSnapshot]
    private let unmount: (String, @escaping (Error?) -> Void) -> Void
    private let forceUnmount: (String, @escaping () -> Void) -> Void
    private let remount: (ServerConfig, @escaping (Result<String, Error>) -> Void) -> Void
    private let remountUnmanaged: (URL, @escaping (Result<String, Error>) -> Void) -> Void
    private let unmountTimeout: TimeInterval
    private let wakeTimeout: TimeInterval

    private var sleepSnapshot: [MountSnapshot] = []
    private var sleepPreparation = DispatchGroup()
    private var isAwaitingReconnect = false
    private var wakeGeneration = UUID()
    private var wakeCancellable: AnyCancellable?
    private var wakeTimeoutWork: DispatchWorkItem?

    init(appState: AppState, networkMonitor: NetworkMonitor, autoMountService: AutoMountService,
         observeWorkspace: Bool = true, unmountTimeout: TimeInterval = 3, wakeTimeout: TimeInterval = 30,
         captureMounts: @escaping ([ServerConfig]) -> [MountSnapshot] = {
             MountingManager.shared.getAllNetworkMounts(matching: $0)
         },
         unmount: @escaping (String, @escaping (Error?) -> Void) -> Void = { path, done in
             MountingManager.shared.unmount(mountPath: path, completion: done)
         },
         forceUnmount: @escaping (String, @escaping () -> Void) -> Void = { path, done in
             DispatchQueue.global(qos: .utility).async {
                 MountingManager.shared.forceUnmount(path: path)
                 DispatchQueue.main.async(execute: done)
             }
         },
         remount: @escaping (ServerConfig, @escaping (Result<String, Error>) -> Void) -> Void = { config, done in
             MountingManager.shared.mount(config: config, silent: true, automatic: true, completion: done)
         },
         remountUnmanaged: @escaping (URL, @escaping (Result<String, Error>) -> Void) -> Void = { url, done in
             MountingManager.shared.remountUnmanaged(url: url, completion: done)
         }) {
        self.appState = appState
        self.networkMonitor = networkMonitor
        self.autoMountService = autoMountService
        self.captureMounts = captureMounts
        self.unmount = unmount
        self.forceUnmount = forceUnmount
        self.remount = remount
        self.remountUnmanaged = remountUnmanaged
        self.unmountTimeout = unmountTimeout
        self.wakeTimeout = wakeTimeout
        if observeWorkspace { subscribeToSleepWake() }
    }

    private func subscribeToSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(handleWillSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(handleDidWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func handleWillSleep(_ notification: Notification) { prepareForSleep() }
    @objc private func handleDidWake(_ notification: Notification) { reconnectAfterWake() }

    func prepareForSleep() {
        cancelWakeWait()
        autoMountService.suspendForSleep()
        DiagnosticsService.shared.breadcrumb(.sleep)
        sleepSnapshot = captureMounts(appState.servers)
        let group = sleepPreparation
        for snapshot in sleepSnapshot {
            group.enter()
            unmountWithTimeout(path: snapshot.volumePath) { group.leave() }
        }
        // Unmount completion is delivered on main. Waiting here would block that completion
        // and force-unmount volumes that have already been gracefully unmounted.
        group.notify(queue: .main) { logger.info("Sleep unmount preparation complete") }
    }

    func reconnectAfterWake() {
        cancelWakeWait()
        autoMountService.suspendForSleep()
        DiagnosticsService.shared.breadcrumb(.wake)
        isAwaitingReconnect = true
        let generation = wakeGeneration
        // Invalidate the cached fingerprint BEFORE subscribing to its current value.
        networkMonitor.refreshAfterWake()
        wakeCancellable = networkMonitor.$currentFingerprint
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fingerprint in
                guard let self else { return }
                self.sleepPreparation.notify(queue: .main) { [weak self] in
                    guard let self, self.isAwaitingReconnect, self.wakeGeneration == generation else { return }
                    guard self.networkMonitor.currentFingerprint == fingerprint else { return }
                    self.handleNetworkReady(fingerprint: fingerprint)
                }
            }

        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self, self.isAwaitingReconnect, self.wakeGeneration == generation else { return }
            DiagnosticsService.shared.begin(.wakeReconnect, automatic: true).finish(error: ConnectionError.timeout)
            let count = self.sleepSnapshot.count
            self.sleepSnapshot = []
            self.cancelWakeWait()
            // A later network update may retry; don't leave automatic mounting permanently suspended.
            let resumeGeneration = self.wakeGeneration
            self.sleepPreparation.notify(queue: .main) { [weak self] in
                guard let self, self.wakeGeneration == resumeGeneration else { return }
                self.autoMountService.resumeAfterWake()
                if let fingerprint = self.networkMonitor.currentFingerprint {
                    self.autoMountService.evaluateAutoMount(for: fingerprint)
                }
            }
            if count > 0 { NotificationService.shared.notifyWakeReconnectFailed(count: count) }
        }
        wakeTimeoutWork = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + wakeTimeout, execute: timeoutWork)
    }

    private func handleNetworkReady(fingerprint: NetworkFingerprint) {
        let snapshots = sleepSnapshot
        sleepSnapshot = []
        cancelWakeWait()
        autoMountService.resumeAfterWake()
        autoMountService.evaluateAutoMount(for: fingerprint)

        for snapshot in snapshots {
            if let id = snapshot.serverID {
                guard let config = appState.servers.first(where: { $0.id == id }), snapshot.matches(config) else { continue }
                // AutoMountService owns enabled rules, including VPN routing decisions.
                guard !config.hasEnabledAutoMountRules else { continue }
                restore(config: config)
            } else if !appState.isSavingServer {
                // Preserve the original URL/port, but suppress system login UI and discard URL passwords.
                remountUnmanaged(snapshot.remountURL) { _ in }
            }
        }
    }

    private func restore(config: ServerConfig) {
        guard !appState.isSavingServer, !(appState.serverOperations[config.id]?.isBusy ?? false) else { return }
        appState.serverOperations[config.id] = .connecting
        remount(config) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      let current = self.appState.servers.first(where: { $0.id == config.id }),
                      current.mountURLString == config.mountURLString else { return }
                switch result {
                case .success(let path): self.appState.serverOperations[config.id] = .mounted(path)
                case .failure(let error):
                    self.appState.serverOperations[config.id] = .failed(error.localizedDescription, mountPath: nil)
                }
            }
        }
    }

    private func cancelWakeWait() {
        isAwaitingReconnect = false
        wakeGeneration = UUID()
        wakeCancellable?.cancel()
        wakeCancellable = nil
        wakeTimeoutWork?.cancel()
        wakeTimeoutWork = nil
    }

    private func unmountWithTimeout(path: String, completion: @escaping () -> Void) {
        // A force-unmount can finish before the original diskutil process exits.
        // Wait for both without blocking main so a late request cannot unmount a restored volume.
        let pending = DispatchGroup()
        pending.enter()
        var gracefulFinished = false
        var fallbackStarted = false
        let startFallback = { [weak self] in
            guard let self, !fallbackStarted else { return }
            fallbackStarted = true
            pending.enter()
            self.forceUnmount(path) {
                DispatchQueue.main.async { pending.leave() }
            }
        }
        let timeout = DispatchWorkItem {
            guard !gracefulFinished else { return }
            startFallback()
        }
        unmount(path) { error in
            DispatchQueue.main.async {
                guard !gracefulFinished else { return }
                gracefulFinished = true
                timeout.cancel()
                if error != nil { startFallback() }
                pending.leave()
            }
        }
        pending.notify(queue: .main, execute: completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + unmountTimeout, execute: timeout)
    }

    deinit {
        cancelWakeWait()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
