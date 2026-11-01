import Foundation
import Network
import Security
import UserNotifications

struct DiagnosticFailure {
    let family: String
    let code: Int
    let expected: Bool
    let nfsReason: NFSMountFailureReason?
    let nfsTool: NFSMountTool?

    init(_ error: Error) {
        expected = Self.isExpected(error)
        if let error = error as? MountError, case .nfsMountFailed(_, let reason, let tool) = error {
            nfsReason = reason
            nfsTool = tool
        } else {
            nfsReason = nil
            nfsTool = nil
        }
        switch error {
        case let error as MountError:
            switch error {
            case .mountFailed(let value): family = "mount"; code = Int(value)
            case .nfsMountFailed(let value, _, _): family = "nfs_mount"; code = Int(value)
            case .nfsAuthorizationRequired: family = "nfs_authorization"; code = 0
            case .invalidURL: family = "invalid_url"; code = 0
            case .invalidShare: family = "invalid_share"; code = 0
            case .timedOut: family = "timeout"; code = 0
            case .keychainReadFailed(let value): family = "keychain"; code = Int(value)
            case .cancellationFailed(let value): family = "cancellation"; code = Int(value)
            case .authenticationRequired: family = "authentication_required"; code = 0
            case .authenticationFailed: family = "authentication_failed"; code = 0
            }
        case let error as UnmountError:
            switch error { case .toolFailed(let value): family = "diskutil"; code = Int(value) }
        case let error as KeychainManager.ReadError:
            switch error { case .status(let value): family = "keychain"; code = Int(value) }
        case let error as ConnectionError:
            switch error {
            case .timeout: family = "timeout"; code = 0
            case .cancelled: family = "cancelled"; code = 0
            case .connectionFailed: family = "connection"; code = 0
            }
        case let error as WOLError:
            switch error {
            case .invalidMACAddress: family = "invalid_mac"; code = 0
            case .sendFailed: family = "wol_send"; code = 0
            }
        case let error as NWError:
            switch error {
            case .posix(let value): family = "posix"; code = Int(value.rawValue)
            case .dns(let value): family = "dns"; code = Int(value)
            case .tls(let value): family = "tls"; code = Int(value)
            default: family = "network"; code = 0
            }
        default:
            let nsError = error as NSError
            // The domain and localizedDescription can contain hosts, paths or credentials.
            switch nsError.domain {
            case NSCocoaErrorDomain: family = "cocoa"
            case NSPOSIXErrorDomain: family = "posix"
            case NSOSStatusErrorDomain: family = "osstatus"
            case NSURLErrorDomain: family = "url"
            case UNErrorDomain: family = "notification"
            default: family = "other"
            }
            code = nsError.code
        }
    }

    private static func isExpected(_ error: Error) -> Bool {
        if let error = error as? MountError {
            if case .nfsMountFailed(_, let reason, _) = error,
               reason == .cancelled || reason == .authorizationRequired { return true }
            if error == .mountFailed(EBUSY) || error == .keychainReadFailed(errSecUserCanceled) || error == .nfsAuthorizationRequired { return true }
        }
        if let error = error as? ConnectionError, case .cancelled = error { return true }
        if let error = error as? KeychainManager.ReadError,
           case .status(let status) = error, status == errSecUserCanceled { return true }
        let nsError = error as NSError
        return (nsError.domain == UNErrorDomain && nsError.code == UNError.Code.notificationsNotAllowed.rawValue)
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
    }

    static let families: Set<String> = [
        "mount", "nfs_mount", "nfs_authorization", "diskutil", "notification", "invalid_url", "invalid_share", "timeout", "keychain", "cancellation",
        "authentication_required", "authentication_failed", "cancelled", "connection",
        "invalid_mac", "wol_send", "posix", "dns", "tls", "network", "cocoa", "osstatus", "url", "other"
    ]
}
