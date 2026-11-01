# NetMounter diagnostics

## Project and collection preference

- Organization: `context-tech-gq`; team: `context-tech`; project: `net-mounter` (`apple-macos`).
- Project ID: `4512317660725248`; ingestion region: US.
- SDK: official static `sentry-cocoa` 9.31.0 XCFramework, pinned URL/checksum in `NetMounter/Package.swift`. Only this variant is downloaded. The app links the system C++ runtime, not a separate Sentry dynamic framework.
- The DSN in `DiagnosticsService` is a public ingestion identifier, **not** an authenticated administration/upload token.
- Settings → Diagnostics → **Share diagnostic data** is on by default when no choice has been saved. Users can turn it off; a saved off/on choice is respected across launches and is never overwritten by the default. The SDK does not start when collection is disabled.
- Hover over the **question-mark button** beside **Share diagnostic data** for the localized collection/privacy tooltip, or click it to open the same explanation in a popover. The help button is separate from the collection switch, so opening the explanation does not change the saved preference.
- Turning it off stops new collection and attempts to remove the dedicated `Caches/NetMounterDiagnostics` cache. SDK shutdown can finish already queued reports. Sent reports cannot be recalled.
- No changes to server configuration, credentials, mount state or existing app installations are needed to enable diagnostics.

## Collected signals

`DiagnosticOperation` is the closed vocabulary. `DiagnosticsService` is the only application boundary that sends data to Sentry.

| Area | Signals |
| --- | --- |
| App/UI | Launch, popover, quit breadcrumbs |
| Mounting | SMB/NFS mount, unmount, force-unmount duration and result |
| Automatic recovery | Attempts, retry scheduling/exhaustion, stale mounts, WOL timeout |
| Sleep/wake | Sleep/wake breadcrumbs, reconnection failures, manual remount and force-unmount result |
| Network/discovery | Network change, reachability timing, discovery/subnet scan breadcrumbs, browser and SMB/NFS share enumeration errors |
| WOL | Validation, packet construction, send errors and timing |
| Configuration | Load/save errors; missing first-run config is normal |
| Keychain | Save/read/delete numeric OSStatus only; never query/account/password content |
| System integration | Privileged NFS helper installation, login item registration, notification authorization/delivery |
| Native failure | Crash handler and uncaught NSException reporting, stack addresses and debug image UUIDs |

- Handled failures are captured without sampling, but deduplicated by operation/family/code/protocol (plus NFS reason/tool when present) for 60 seconds, with at most 20 distinct error keys per minute per running app.
- Manual root operation transactions are sampled at 20%. Automatic network, file, Core Data, UI and performance collectors are disabled.
- Routine unreachable-host checks do not generate standalone issues. Expected cancellations (including cancellation while reading a saved Keychain password), notification permission refusal (`UNErrorDomain` / `notificationsNotAllowed`), and an already-mounted result (`EBUSY`) are suppressed as issues. Notification authorization and delivery have separate operation names.
- Diagnostics test bypasses error deduplication. Its DEBUG-only button reports that the test was **queued**, not that the server received it.
- Error counts are **not** total failure counts because of deduplication/limits. No stable user identity is collected; Sentry's “users impacted” is not a reliable affected-user metric.
- A handled-error stack identifies the capture/completion site, not necessarily the original throw site. Native crashes need matching symbols for useful code locations.

## Recovery and error classification

- Automatic mounts, including their first attempt and wake recovery, are tagged `trigger:automatic`; whether a system UI is suppressed is not used to infer the trigger.
- NFS `mount_nfs`/helper process exit statuses use `nfs_mount`, not POSIX mount errno or server-password failures. Tool stderr is drained with a 16 KiB retention limit and converted to a closed reason; a truncated incomplete line is ignored. Raw output is then discarded, never logged or forwarded to Sentry. Only validated `nfs_reason` and `nfs_tool` values survive the sanitizer.
- Missing authorization for explicit reserved-port automatic NFS mounting uses `nfs_authorization` and is expected, not a Sentry issue. Ordinary-user NFS mounting never falls back to privileged execution.
- `diskutil` process exit statuses use the `diskutil` error family, not mount errno. In particular, exit status 1 does not establish a POSIX permission failure. An already-disappeared mount is an idempotent unmount success.
- `EEXIST` is success only when the same source (protocol, host, effective port and full share/export path) is confirmed alive. Otherwise it stops automatic retries; stale cleanup failure also stops the mount attempt.
- Retry exhaustion retains the final mount failure classification instead of replacing it with a generic connection error.
- Keychain OSStatus `-67049` is `errSecCSBadObjectFormat`, not a wrong-password error. A signing/validation problem is a diagnostic lead, not a proven cause for every historical report; `-67050` is the distinct `errSecCSReqFailed` status. Neither causes the app to overwrite a saved password.
- Packaging now uses the full app version as `CFBundleVersion` and accepts an explicit `NETMOUNTER_SIGNING_IDENTITY`. This does not uniquely identify two rebuilds of the same version; preserve and verify matching binary/dSYM UUIDs.

Wake recovery waits for both the original unmount process and any force fallback to finish. If a system unmount tool remains hung, automatic recovery stays paused rather than starting a mount that the old request could later unmount. The app does not block the main thread or request a system sleep deferral.

These changes require a new build to take effect. Isolated regression tests do not establish that real NAS mounts, physical sleep/wake, Keychain UI, or production native symbolication have been fixed.

## Privacy boundaries

Only numeric error codes, fixed error families/operation names, protocol/trigger/outcome, duration, validated app/OS versions and architecture/memory metadata are included. Stack addresses, executable/source basenames and debug UUIDs are retained for symbolication.

Original log messages, NSError descriptions/userInfo, passwords, usernames, server names/IPs, share paths, local path prefixes and MAC addresses are not forwarded. The sanitizer drops arbitrary tags, request/user/extra fields, exception reasons, thread names, kernel version, source context and frame variables. Automatic breadcrumbs, logs, metrics, MetricKit and memory introspection are disabled. Screenshot/replay/view hierarchy collection is not enabled. Hang reporting is disabled to avoid treating legitimate Keychain/admin waits as app failures.

Sentry necessarily processes the connection's source IP. SDK `sendDefaultPii=false` alone does not prevent server-side geographic enrichment. This project's Security & Privacy settings have:

1. Server-side/default data scrubbing enabled.
2. **Prevent IP addresses from being stored** enabled.
3. Advanced rule: `[Remove] [Anything] from [$user.geo.**]` for errors/transactions/attachments.

These rules affect **new** events; they do not erase historical events or imply that the service never processes an IP. The initial verification event predates the geo rule. Avoid forwarding raw application logs to work around the sanitizer.

## Build, test and verify

From the repository root:

```sh
swift test --package-path NetMounter
swift build --package-path NetMounter -c release --arch arm64 --arch x86_64
./scripts/verify_sentry.sh
```

The verifier explicitly sends one synthetic error and one transaction from a freshly built DEBUG executable in a temporary app bundle. It bypasses logging setup, server configuration, Keychain, notifications, mounts and scans; does not persist consent; flushes for up to 15 seconds; and removes its temporary bundle/cache. It does not crash the app. Inspect Sentry separately to confirm receipt.

Verification on 2026-10-26 (Asia/Shanghai):

- Full suite: 93 tests, 1 skipped, 0 failures. Includes missing-preference default-on, persisted off/on choices and disabled-startup coverage. Preference tests use isolated stores without enabling the SDK or sending events.
- The opt-in offscreen UI fixture also passed separately; English and Simplified Chinese diagnostics text fit the settings layout. This was a render check with isolated preferences, not an interactive toggle test.
- Universal release build passed; arm64 and x86_64 executable/dSYM UUIDs matched; no Sentry dynamic framework dependency.
- Latest synthetic error: `NET-MOUNTER-1`, event `a332c9253a2c403fb9ed17479202e38e`, at `2026-10-25T16:18:17.203Z` (`2026-10-26 00:18:17` Shanghai).
- Associated trace: `1de82e1393284bedb4397a2595d3197b`, operation `diagnostics.verification`, ~30 ms.
- Environment: `development`; release: `net-mounter@0.0.0`. Fresh event no longer exposed user geo or kernel version in the backend event details.
- These checks prove handled-error/transaction ingestion, **not** end-to-end fatal crash capture or production symbolication.

Useful issue filters: `environment:production operation:mount`, `error_family:timeout`, `protocol:nfs`, `operation:automount.exhausted`. Compare releases and operation durations; do not infer actual mount health from an issue alone.

## Symbols before distribution

1. Build the exact release that will ship, and preserve its matching `NetMounter.dSYM` **outside** the distributed `.app`.
2. Compare `xcrun dwarfdump --uuid <binary>` with `xcrun dwarfdump --uuid <dSYM>` for both architectures. Rebuilding changes UUIDs, even with the same version.
3. Install the official `sentry-cli`. Have an authorized maintainer configure an appropriately scoped organization upload token as `SENTRY_AUTH_TOKEN` in their environment or CI secret store. Never put its value in source, command arguments, screenshots or chat.
4. Run `./scripts/upload_sentry_symbols.sh /absolute/path/to/NetMounter.dSYM` before distribution. It fails visibly if the CLI/token is missing and uploads only the selected dSYM, without `--include-sources`.
5. Verify the matching debug IDs in Sentry, then test a new event from that exact binary. Native crash acceptance also requires an intentionally isolated crash/relaunch test.

No upload token is installed in this workspace and no dSYM was uploaded during integration. At that integration stage, no installed app was replaced and no release was published. Packaging can reuse an old binary: build explicitly before packaging; never assume a packaged app includes the latest diagnostics changes.

## v1.4.0 pre-release review

- Full suite: 97 tests, 2 opt-in UI tests skipped, 0 failures. The two UI tests also passed in a separate opt-in run; the diagnostics help button opens a localized popover in English/Chinese with collection both on/off, without changing the preference.
- Added regressions for NFS traversal/option-like host rejection before system access, and release version/staging updates for both website languages. Existing credential-save rollback and mount cancellation/late-completion coverage passed.
- Removed personal workspace paths from checked-in tooling/review notes. No administration tokens or private keys were found in the changed files. The public Sentry ingestion DSN is intentionally retained.
- Packaging removes debug-map build paths from the distributed executable only, before signing; the original build and dSYM are unchanged. Packaging regression tests check stripping arguments/order and preservation of the original binary.
- Rebuilt the universal release app and inspected its DMG read-only: version 1.4.0, English/Chinese resources present, signature integrity valid, only system dynamic dependencies, no local user paths or dSYMs in the distributed bundle. Executable/dSYM UUIDs match for arm64 and x86_64.
- Distribution remains ad-hoc signed and unnotarized. Sentry symbol upload is still pending because an upload token/CLI is unavailable; production symbolication and fatal-crash/relaunch acceptance are not claimed.


## NFS diagnostics follow-up — 2026-11-01

- Historical baseline: `NET-MOUNTER-D` (`mount`, `nfs_mount:1`) and `NET-MOUNTER-E` (`automount.exhausted`, `nfs_mount:1`), previously observed on 2026-10-28 UTC. Their exit status did not establish NAS export refusal, a reserved-port requirement, or a need for root privileges.
- This session could not access authenticated Sentry issue/event tools. Events since `2026-10-28T17:38:00Z`, including new occurrences of existing issues, have **not** been reviewed. No issue has been resolved in Sentry.
- Local changes distinguish permission, missing path, timeout, unreachable service, invalid arguments, tool authorization and cancellation, leaving unrecognized output as `unknown`. They do not infer errno from exit status or infer a wrong NAS password from a tool-authorization failure.
- Unknown/network/timeout failures retain automatic retry. Recognized failures requiring user action stop automatic retries until an explicit retry or configuration change; automatic health checks do not resume them. Expected authorization requirements and cancellations do not become error issues.
- NFS reason/tool participate in deduplication and grouping. Newly classified failures can create different issues from the historical D/E groups; lack of new events in D/E alone is not evidence of recovery.
- Validation: 137 tests, 2 opt-in UI tests skipped, 0 failures; arm64/x86_64 Release build passed; English/Chinese string files passed plist validation. Synthetic subprocess tests exercise pipe draining beyond 16 KiB and truncation boundaries without invoking mounting or privilege escalation.
- No running app was replaced, release published, symbols uploaded, helper installed, mount changed, or credentials/Keychain data modified. The current running local app is still labeled 1.4.0 and does not include this follow-up. Real NAS mounting, system authorization dialogs, new backend receipt and production symbolication remain unverified.
