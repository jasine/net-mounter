# NFS Passwordless Mount Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install a root-owned wrapper script + narrow sudoers rule when the first NFS server is saved, so NFS auto-mounts stop prompting for a password every launch.

**Architecture:** A new `PrivilegedMountInstaller` service owns three hardcoded script constants and two operations: `isInstalled` (existence check of two files) and `install` (one `osascript … with administrator privileges` call that writes both files). `MountingManager.mountNFS` branches on `isInstalled`: installed → `sudo -n <wrapper>`, not installed → existing osascript fallback. `ServerDetailView.save()` triggers `install` after saving an NFS config when not yet installed.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest, Foundation `Process`, `/usr/bin/osascript`, `/usr/bin/sudo`, `visudo`.

## Global Constraints

- macOS 14.0+, Swift 5.9, non-sandboxed menu bar app.
- Wrapper script path: `/Library/Application Support/NetMounter/nfs-mount.sh`, owner `root:wheel`, mode `755`.
- sudoers fragment path: `/etc/sudoers.d/netmounter`, mode `440`, space in path escaped with `\`.
- sudoers content (exact): `ALL ALL=(root) NOPASSWD: /Library/Application\ Support/NetMounter/nfs-mount.sh`
- All privileged scripts are hardcoded constants — never interpolate user input into script bodies. Mount point / source are passed as `Process.arguments` only.
- `isInstalled` = BOTH `/etc/sudoers.d/netmounter` AND the wrapper script exist.
- User cancelling the auth prompt must NOT block config save; NFS mount falls back to osascript.

---

### Task 1: PrivilegedMountInstaller — constants and `isInstalled`

**Files:**
- Create: `NetMounter/Sources/NetMounter/Services/PrivilegedMountInstaller.swift`
- Test: `NetMounter/Tests/NetMounterTests/PrivilegedMountInstallerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum PrivilegedMountInstaller` with static constants:
    - `static let wrapperScriptPath = "/Library/Application Support/NetMounter/nfs-mount.sh"`
    - `static let sudoersPath = "/etc/sudoers.d/netmounter"`
    - `static let wrapperScriptBody: String`
    - `static let sudoersBody: String`
  - `static func isInstalled(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool`
    (injectable existence check for testing; default uses FileManager.)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import NetMounter

final class PrivilegedMountInstallerTests: XCTestCase {

    func testIsInstalled_bothFilesPresent_returnsTrue() {
        let present: Set<String> = [
            PrivilegedMountInstaller.wrapperScriptPath,
            PrivilegedMountInstaller.sudoersPath,
        ]
        XCTAssertTrue(PrivilegedMountInstaller.isInstalled { present.contains($0) })
    }

    func testIsInstalled_onlyScriptPresent_returnsFalse() {
        let present: Set<String> = [PrivilegedMountInstaller.wrapperScriptPath]
        XCTAssertFalse(PrivilegedMountInstaller.isInstalled { present.contains($0) })
    }

    func testIsInstalled_onlySudoersPresent_returnsFalse() {
        let present: Set<String> = [PrivilegedMountInstaller.sudoersPath]
        XCTAssertFalse(PrivilegedMountInstaller.isInstalled { present.contains($0) })
    }

    func testIsInstalled_neitherPresent_returnsFalse() {
        XCTAssertFalse(PrivilegedMountInstaller.isInstalled { _ in false })
    }

    func testWrapperScript_restrictsMountpointToVolumes() {
        // Guard clause must reject mountpoints outside /Volumes and reject path traversal.
        XCTAssertTrue(PrivilegedMountInstaller.wrapperScriptBody.contains("/Volumes/*"))
        XCTAssertTrue(PrivilegedMountInstaller.wrapperScriptBody.contains("*..*"))
        XCTAssertTrue(PrivilegedMountInstaller.wrapperScriptBody.contains("/sbin/mount_nfs"))
    }

    func testSudoersBody_escapesSpaceInPath() {
        XCTAssertTrue(PrivilegedMountInstaller.sudoersBody.contains(#"/Library/Application\ Support/NetMounter/nfs-mount.sh"#))
        XCTAssertTrue(PrivilegedMountInstaller.sudoersBody.contains("NOPASSWD:"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd NetMounter && swift test --filter PrivilegedMountInstallerTests`
Expected: FAIL — `cannot find 'PrivilegedMountInstaller' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

enum PrivilegedMountInstaller {

    static let wrapperScriptPath = "/Library/Application Support/NetMounter/nfs-mount.sh"
    static let sudoersPath = "/etc/sudoers.d/netmounter"

    /// Root-owned NFS mount helper. Installed root:wheel 755 so the sudoers
    /// NOPASSWD rule targets a fixed, tamper-proof script rather than a
    /// general-purpose mount binary. Guards restrict it to NFS mounts under /Volumes.
    static let wrapperScriptBody = """
    #!/bin/sh
    # NetMounter NFS mount helper. Installed root-owned; invoked via passwordless sudo.
    set -e
    MOUNTPOINT="$1"
    SOURCE="$2"
    case "$MOUNTPOINT" in
      /Volumes/*) ;;
      *) echo "refusing mountpoint outside /Volumes: $MOUNTPOINT" >&2; exit 1 ;;
    esac
    case "$MOUNTPOINT" in
      *..*) echo "refusing path traversal: $MOUNTPOINT" >&2; exit 1 ;;
    esac
    mkdir -p "$MOUNTPOINT"
    exec /sbin/mount_nfs -o resvport,noowners "$SOURCE" "$MOUNTPOINT"
    """

    static let sudoersBody = #"ALL ALL=(root) NOPASSWD: /Library/Application\ Support/NetMounter/nfs-mount.sh"# + "\n"

    static func isInstalled(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        fileExists(wrapperScriptPath) && fileExists(sudoersPath)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd NetMounter && swift test --filter PrivilegedMountInstallerTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add NetMounter/Sources/NetMounter/Services/PrivilegedMountInstaller.swift NetMounter/Tests/NetMounterTests/PrivilegedMountInstallerTests.swift
git commit -m "feat: add PrivilegedMountInstaller constants and isInstalled check"
```

---

### Task 2: PrivilegedMountInstaller — `install` via osascript

**Files:**
- Modify: `NetMounter/Sources/NetMounter/Services/PrivilegedMountInstaller.swift`
- Test: `NetMounter/Tests/NetMounterTests/PrivilegedMountInstallerTests.swift` (add cases)

**Interfaces:**
- Consumes: `wrapperScriptPath`, `sudoersPath`, `wrapperScriptBody`, `sudoersBody` from Task 1.
- Produces:
  - `enum InstallResult { case installed, cancelled, failed(String) }`
  - `static func installScript() -> String` — returns the full shell script (hardcoded) that the osascript runs. Pure/testable.
  - `static func install(runOSAScript: (String) -> Int32 = defaultRunner, completion: @escaping (InstallResult) -> Void)` — builds the script via `installScript()`, runs it, maps exit code to `InstallResult` (0 → installed, 1 (osascript "User canceled") → cancelled, else → failed). Runs on a background queue in the default runner.

**Interface note:** osascript exits with code **1** when the user cancels the authentication dialog (error -128). Treat exit code 1 as `.cancelled`, any other non-zero as `.failed`.

- [ ] **Step 1: Write the failing tests**

```swift
func testInstallScript_writesBothFilesWithCorrectPermissions() {
    let script = PrivilegedMountInstaller.installScript()
    // Creates parent dir
    XCTAssertTrue(script.contains(#"mkdir -p "/Library/Application Support/NetMounter""#))
    // Writes script then chown/chmod
    XCTAssertTrue(script.contains("chown root:wheel"))
    XCTAssertTrue(script.contains("chmod 755"))
    // sudoers fragment is 440 and syntax-checked, rolled back on failure
    XCTAssertTrue(script.contains("chmod 440"))
    XCTAssertTrue(script.contains("visudo -cf"))
}

func testInstall_exitZero_installed() {
    let exp = expectation(description: "done")
    PrivilegedMountInstaller.install(runOSAScript: { _ in 0 }) { result in
        if case .installed = result {} else { XCTFail("expected installed") }
        exp.fulfill()
    }
    wait(for: [exp], timeout: 1)
}

func testInstall_exitOne_cancelled() {
    let exp = expectation(description: "done")
    PrivilegedMountInstaller.install(runOSAScript: { _ in 1 }) { result in
        if case .cancelled = result {} else { XCTFail("expected cancelled") }
        exp.fulfill()
    }
    wait(for: [exp], timeout: 1)
}

func testInstall_exitOther_failed() {
    let exp = expectation(description: "done")
    PrivilegedMountInstaller.install(runOSAScript: { _ in 42 }) { result in
        if case .failed = result {} else { XCTFail("expected failed") }
        exp.fulfill()
    }
    wait(for: [exp], timeout: 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd NetMounter && swift test --filter PrivilegedMountInstallerTests`
Expected: FAIL — `installScript`/`install` not found.

- [ ] **Step 3: Write minimal implementation**

Add to `PrivilegedMountInstaller`:

```swift
enum InstallResult {
    case installed
    case cancelled
    case failed(String)
}

/// Full shell script executed with administrator privileges. Hardcoded —
/// no user input is interpolated. Writes the wrapper root-owned + the
/// sudoers fragment, then syntax-checks sudoers and rolls back on failure.
static func installScript() -> String {
    let dir = "/Library/Application Support/NetMounter"
    // Heredoc bodies are static constants; safe to embed.
    return """
    set -e
    mkdir -p "\(dir)"
    cat > "\(wrapperScriptPath)" <<'NETMOUNTER_WRAPPER_EOF'
    \(wrapperScriptBody)
    NETMOUNTER_WRAPPER_EOF
    chown root:wheel "\(wrapperScriptPath)"
    chmod 755 "\(wrapperScriptPath)"
    cat > "\(sudoersPath)" <<'NETMOUNTER_SUDOERS_EOF'
    \(sudoersBody)NETMOUNTER_SUDOERS_EOF
    chmod 440 "\(sudoersPath)"
    if ! visudo -cf "\(sudoersPath)"; then
      rm -f "\(sudoersPath)"
      exit 2
    fi
    """
}

static func install(
    runOSAScript: @escaping (String) -> Int32 = defaultRunner,
    completion: @escaping (InstallResult) -> Void
) {
    DispatchQueue.global(qos: .userInitiated).async {
        let code = runOSAScript(installScript())
        let result: InstallResult
        switch code {
        case 0: result = .installed
        case 1: result = .cancelled   // osascript: user canceled auth dialog
        default: result = .failed("install exited with code \(code)")
        }
        DispatchQueue.main.async { completion(result) }
    }
}

/// Default runner: escapes the script for AppleScript and runs it with
/// administrator privileges (one system password prompt).
static let defaultRunner: (String) -> Int32 = { shellScript in
    let escaped = shellScript
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", appleScript]
    do {
        try process.run()
    } catch {
        return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd NetMounter && swift test --filter PrivilegedMountInstallerTests`
Expected: PASS (10 tests total).

- [ ] **Step 5: Commit**

```bash
git add NetMounter/Sources/NetMounter/Services/PrivilegedMountInstaller.swift NetMounter/Tests/NetMounterTests/PrivilegedMountInstallerTests.swift
git commit -m "feat: add PrivilegedMountInstaller.install via osascript"
```

---

### Task 3: MountingManager.mountNFS — use passwordless wrapper when installed

**Files:**
- Modify: `NetMounter/Sources/NetMounter/Services/MountingManager.swift:263-299`

**Interfaces:**
- Consumes: `PrivilegedMountInstaller.isInstalled`, `PrivilegedMountInstaller.wrapperScriptPath` from Tasks 1-2.
- Produces: no new public API; changes internal mount execution.

**Context:** No unit test — `mountNFS` shells out to a real mount. This task is verified by build + manual integration (Task 5). The change must preserve the existing `silent` behavior and the osascript fallback when the rule is not installed.

- [ ] **Step 1: Replace the script-building + execution block**

In `mountNFS`, replace the current block (`MountingManager.swift:268-299`) that builds `shellCmd`/`script` and runs osascript with:

```swift
        let mountProcess = Process()
        let errorPipe = Pipe()

        if PrivilegedMountInstaller.isInstalled() {
            // Passwordless path: root-owned wrapper via `sudo -n` (non-interactive).
            mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            mountProcess.arguments = ["-n", PrivilegedMountInstaller.wrapperScriptPath, mountPoint, nfsSource]
        } else {
            // Fallback: prompt for admin password via osascript (pre-install behavior).
            let shellCmd = "mkdir -p \(shellEscape(mountPoint)) && /sbin/mount -t nfs -o resvport,noowners \(shellEscape(nfsSource)) \(shellEscape(mountPoint))"
            let escapedShellCmd = appleScriptEscape(shellCmd)
            let script = silent
                ? "do shell script \"\(escapedShellCmd)\""
                : "do shell script \"\(escapedShellCmd)\" with administrator privileges"
            mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            mountProcess.arguments = ["-e", script]
        }

        DispatchQueue.global(qos: .userInitiated).async {
            mountProcess.standardError = errorPipe
            do {
                try mountProcess.run()
            } catch {
                wrappedCompletion(.failure(error))
                return
            }

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            mountProcess.waitUntilExit()

            if mountProcess.terminationStatus == 0 {
                wrappedCompletion(.success(mountPoint))
            } else {
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                logger.error("NFS mount failed: \(stderr)")
                wrappedCompletion(.failure(MountError.mountFailed(mountProcess.terminationStatus)))
            }
        }
```

Note: `mountPoint` and `nfsSource` are already computed above at `MountingManager.swift:265-266`; keep those lines.

- [ ] **Step 2: Build to verify it compiles**

Run: `cd NetMounter && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Run existing tests to check for regressions**

Run: `cd NetMounter && swift test`
Expected: PASS (all existing + new tests).

- [ ] **Step 4: Commit**

```bash
git add NetMounter/Sources/NetMounter/Services/MountingManager.swift
git commit -m "feat: mount NFS via passwordless wrapper when sudoers rule installed"
```

---

### Task 4: ServerDetailView.save() — trigger install on first NFS save

**Files:**
- Modify: `NetMounter/Sources/NetMounter/Views/ServerDetailView.swift:208-228`

**Interfaces:**
- Consumes: `PrivilegedMountInstaller.isInstalled`, `PrivilegedMountInstaller.install` from Tasks 1-2.
- Produces: no new API.

**Context:** No unit test — this is SwiftUI glue calling a tested service. Verified by build + manual (Task 5). Install is fire-and-forget: it must not block or delay dismiss, and cancellation/failure must not prevent save.

- [ ] **Step 1: Add the trigger in `save()`**

In `save()`, immediately BEFORE `presentationMode.wrappedValue.dismiss()` (currently `ServerDetailView.swift:227`), insert:

```swift
        // First NFS server: install the passwordless-mount rule (one auth prompt).
        // Fire-and-forget — cancellation or failure does not block saving; NFS
        // mounts then fall back to prompting per-mount.
        if config.serverProtocol == .nfs && !PrivilegedMountInstaller.isInstalled() {
            PrivilegedMountInstaller.install { _ in }
        }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd NetMounter && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Run tests to check for regressions**

Run: `cd NetMounter && swift test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add NetMounter/Sources/NetMounter/Views/ServerDetailView.swift
git commit -m "feat: install passwordless NFS mount rule on first NFS server save"
```

---

### Task 5: Manual integration verification

**Files:** none (verification only).

**Context:** Requires a real NFS server on the network. Automated tests cannot exercise the privileged path. Use the `superpowers:verification-before-completion` mindset: drive the real flow.

- [ ] **Step 1: Clean slate**

Run:
```bash
sudo rm -f /etc/sudoers.d/netmounter
sudo rm -f "/Library/Application Support/NetMounter/nfs-mount.sh"
```
Expected: both removed (or already absent).

- [ ] **Step 2: Build and run the app**

Run: `cd NetMounter && make run` (or `swift run`)
Expected: menu bar app launches.

- [ ] **Step 3: Save first NFS server**

Add a server with Protocol=NFS, a real host, and export path (e.g. `/volume1/media`). Save.
Expected: exactly ONE macOS admin password prompt appears. Enter password.

- [ ] **Step 4: Verify files installed correctly**

Run:
```bash
ls -l@ "/Library/Application Support/NetMounter/nfs-mount.sh"
ls -l /etc/sudoers.d/netmounter
sudo visudo -cf /etc/sudoers.d/netmounter
```
Expected: script is `-rwxr-xr-x root wheel`; sudoers is `-r--r-----`; `visudo` prints "parsed OK".

- [ ] **Step 5: Verify passwordless mount**

Trigger a mount of the NFS server from the menu bar (or restart the app so auto-mount runs).
Expected: NFS mounts with NO password prompt. Volume appears under `/Volumes`.

- [ ] **Step 6: Verify cancellation fallback (fresh slate)**

Repeat Step 1 (remove files), relaunch, save an NFS server, and CANCEL the password prompt.
Expected: config still saved (server appears in list); subsequent NFS mount falls back to prompting for a password.

- [ ] **Step 7: Record results**

Note pass/fail for each step in the PR description. If any step fails, stop and report before merging.

---

## Self-Review

**1. Spec coverage:**
- Wrapper script (root:wheel 755, /Volumes guard, path-traversal guard, mount_nfs) → Task 1 constants + Task 2 install script. ✓
- sudoers fragment (440, space-escaped, NOPASSWD, visudo check + rollback) → Task 1 `sudoersBody` + Task 2 `installScript`. ✓
- `isInstalled` = both files exist → Task 1. ✓
- Install via one osascript prompt, exit-code mapping (cancel = no block) → Task 2. ✓
- mountNFS branches installed vs fallback, preserves `silent` → Task 3. ✓
- Trigger on save when NFS + not installed; edit also triggers (per spec) → Task 4. ✓
- No cancellation blocking save → Task 4 fire-and-forget + Task 5 Step 6. ✓
- Manual verification (real NFS) → Task 5. ✓

**2. Placeholder scan:** No TBD/TODO; all code shown in full; commands have expected output. ✓

**3. Type consistency:** `InstallResult`, `isInstalled(fileExists:)`, `install(runOSAScript:completion:)`, `installScript()`, `defaultRunner`, `wrapperScriptPath`, `sudoersPath`, `wrapperScriptBody`, `sudoersBody` — names identical across Tasks 1-4. ✓
