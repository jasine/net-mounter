import Sentry
import XCTest
@testable import NetMounter

final class NFSFailureDiagnosticsTests: XCTestCase {
    func testSameExitStatusHasDifferentReasonsWithoutTreatingItAsErrno() {
        let cases: [(String, NFSMountFailureReason)] = [
            ("mount_nfs: can't mount /exports/test from nas.invalid: Permission denied", .permissionDenied),
            ("mount_nfs: can't mount /exports/test: Operation not permitted", .permissionDenied),
            ("mount_nfs: can't mount /exports/test: No such file or directory", .notFound),
            ("mount_nfs: RPC: Timed out", .timeout),
            ("mount_nfs: can't mount /exports/test: Connection refused", .networkUnavailable),
            ("mount_nfs: no usable addresses for host: nas.invalid", .networkUnavailable),
            ("mount_nfs: illegal option -- Q", .invalidOptions),
            ("unrecognized output containing private-test-value", .unknown),
            ("", .unknown)
        ]
        for (output, reason) in cases {
            let result = NFSMountToolResult(status: 1, stderr: output, tool: .mountNFS)
            XCTAssertEqual(result.reason, reason)
            XCTAssertEqual(result.status, 1)
        }
    }

    func testErrorLikeHostAndPathNamesAreNotClassifiedAsFailureReasons() {
        let text = "mount_nfs: can't mount /exports/Permission denied from timeout.invalid: unexpected error"
        XCTAssertEqual(NFSMountToolResult(status: 1, stderr: text).reason, .unknown)
        XCTAssertEqual(NFSMountToolResult(status: 1, stderr: "mount_nfs: private-test-value").reason, .unknown)
    }

    func testToolAuthorizationIsNotMistakenForNASPermissionOrPasswordError() {
        let output = "sudo: a password is required"
        XCTAssertEqual(NFSMountToolResult(status: 1, stderr: output, tool: .sudo).reason, .authorizationRequired)
        XCTAssertEqual(NFSMountToolResult(status: 1, stderr: output, tool: .mountNFS).reason, .unknown)
        XCTAssertEqual(NFSMountToolResult(status: 1, stderr: "execution error: User canceled. (-128)", tool: .appleScript).reason, .cancelled)
        XCTAssertEqual(NFSMountToolResult(status: 1, stderr: "execution error: User canceled. (-128)", tool: .mountNFS).reason, .unknown)
        let error = MountError.nfsMountFailed(1, reason: .authorizationRequired, tool: .sudo)
        XCTAssertFalse(error.isAuthError)
        XCTAssertTrue(error.isNonRetryable)
        XCTAssertTrue(DiagnosticFailure(error).expected)
    }

    func testOnlyActionableFailuresStopRetriesNotGenericExitOneOrNetworkErrors() {
        for reason in [NFSMountFailureReason.unknown, .timeout, .networkUnavailable] {
            XCTAssertFalse(MountError.nfsMountFailed(1, reason: reason).isNonRetryable)
        }
        for reason in [NFSMountFailureReason.permissionDenied, .notFound, .invalidOptions, .authorizationRequired, .cancelled] {
            XCTAssertTrue(MountError.nfsMountFailed(1, reason: reason).isNonRetryable)
        }
    }

    func testDiagnosticTagsAreClosedAndDistinctReasonsDoNotShareFingerprint() {
        let event = Event(level: .error)
        event.tags = ["operation": "mount", "error_family": "nfs_mount", "error_code": "1", "protocol": "nfs",
                      "nfs_reason": "permission_denied", "nfs_tool": "mount_nfs", "stderr": "private-test-value"]
        DiagnosticsService.sanitize(event)
        XCTAssertEqual(event.tags?["nfs_reason"], "permission_denied")
        XCTAssertEqual(event.tags?["nfs_tool"], "mount_nfs")
        XCTAssertNil(event.tags?["stderr"])
        let deniedFingerprint = event.fingerprint
        event.tags?["nfs_reason"] = "timeout"
        DiagnosticsService.sanitize(event)
        XCTAssertNotEqual(event.fingerprint, deniedFingerprint)
        event.tags?["nfs_reason"] = "private-test-value"
        event.tags?["nfs_tool"] = "/private/test/path"
        DiagnosticsService.sanitize(event)
        XCTAssertNil(event.tags?["nfs_reason"])
        XCTAssertNil(event.tags?["nfs_tool"])
    }

    func testNFSTagsDoNotAttachToOtherErrorFamilies() {
        let event = Event(level: .error)
        event.tags = ["operation": "mount", "error_family": "keychain", "error_code": "1",
                      "nfs_reason": "permission_denied", "nfs_tool": "sudo"]
        DiagnosticsService.sanitize(event)
        XCTAssertNil(event.tags?["nfs_reason"])
        XCTAssertNil(event.tags?["nfs_tool"])
    }

    func testPipeIsDrainedPastRetentionLimitWithoutLeakingToolOutput() throws {
        // Exercise a real pipe with a harmless synthetic command, never a mount or sudo.
        let result = try NFSMountToolResult.run(executable: "/bin/sh", arguments: ["-c",
            "printf 'mount_nfs: Permission denied\\n' >&2; i=0; while [ $i -lt 8192 ]; do printf 'private-test-value-0123456789abcdef\\n' >&2; i=$((i+1)); done; exit 1"], tool: .mountNFS)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.reason, .permissionDenied)
        let error = MountError.nfsMountFailed(result.status, reason: result.reason, tool: .mountNFS)
        XCTAssertFalse(error.localizedDescription.contains("private-test-value"))
        let failure = DiagnosticFailure(error)
        XCTAssertEqual(failure.nfsReason, .permissionDenied)
        XCTAssertEqual(failure.nfsTool, .mountNFS)
    }

    func testTruncatedPathDoesNotBecomeAPermissionError() throws {
        let suffix = "Permission denied"
        let output = String(repeating: "x", count: 16_384 - suffix.utf8.count)
            + suffix + " from nas.invalid: unexpected error\n"
        let result = try NFSMountToolResult.run(executable: "/bin/sh", arguments: ["-c",
            "printf '%s' \"$1\" >&2; exit 1", "nfs-test", output], tool: .mountNFS)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.reason, .unknown)
    }

    func testSuccessfulToolOutputIsNotClassifiedAsFailure() {
        XCTAssertEqual(NFSMountToolResult(status: 0, stderr: "Permission denied", tool: .mountNFS).reason, .unknown)
    }
}
