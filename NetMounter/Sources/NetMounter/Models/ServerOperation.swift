import Foundation

/// Shared by automatic operations and rows, including across popover recreation.
enum ServerOperation: Equatable {
    case idle
    case waitingForNetwork
    case connecting
    case disconnecting(String)
    case mounted(String)
    case failed(String, mountPath: String?)

    var isBusy: Bool {
        switch self {
        case .connecting, .disconnecting: return true
        default: return false
        }
    }

    var mountPath: String? {
        switch self {
        case .mounted(let path), .disconnecting(let path): return path
        case .failed(_, let path): return path
        default: return nil
        }
    }

    var isMounted: Bool { mountPath != nil }

    var errorMessage: String? {
        if case .failed(let message, _) = self { return message }
        return nil
    }

    var summary: String {
        switch self {
        case .idle: return String(localized: "Not mounted", bundle: .module)
        case .waitingForNetwork: return String(localized: "Waiting for network", bundle: .module)
        case .connecting: return String(localized: "Connecting…", bundle: .module)
        case .disconnecting: return String(localized: "Unmounting…", bundle: .module)
        case .mounted: return String(localized: "Mounted", bundle: .module)
        case .failed(_, let path):
            return path == nil ? String(localized: "Mount failed", bundle: .module)
                : String(localized: "Unmount failed — still mounted", bundle: .module)
        }
    }

    func refreshed(mountPath: String?, hasNetwork: Bool, mountInFlight: Bool) -> Self {
        if isBusy { return self }
        if mountInFlight {
            // A failed cancellation leaves the native request pending; retain its actionable error.
            if case .failed = self { return self }
            return .connecting
        }
        if case .failed(let message, let previousPath) = self {
            // Keep mount failures until retry; clear an unmount failure only once the volume is gone.
            if previousPath == nil {
                if let mountPath { return .mounted(mountPath) }
                return self
            }
            if let mountPath { return .failed(message, mountPath: mountPath) }
        }
        if let mountPath { return .mounted(mountPath) }
        return hasNetwork ? .idle : .waitingForNetwork
    }
}

struct ReachabilityCheckState {
    private var request: UUID?
    private(set) var result: Bool?
    var isRunning: Bool { request != nil }

    mutating func start() -> UUID {
        let id = UUID()
        request = id
        result = nil
        return id
    }

    mutating func reset() {
        request = nil
        result = nil
    }

    mutating func complete(request id: UUID, reachable: Bool) {
        guard request == id else { return }
        request = nil
        result = reachable
    }
}
