# SMB via mount_smbfs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mount SMB shares via a `/sbin/mount_smbfs` subprocess instead of the hanging `NetFSMountURLSync`; AFP/WebDAV stay on NetFS.

**Architecture:** `mount(config:)` dispatches `.smb` to a new `mountSMB` that builds a percent-encoded `smb://user:pass@host/share` URL and runs `/sbin/mount_smbfs <url> <mountpoint>` as a subprocess (args array, no shell). The existing in-flight lock, timeout, share validation, and error classification are reused. AFP/WebDAV keep calling the existing `mountNetFS`/`NetFSMountURLSync` path.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest, Foundation `Process`, `/sbin/mount_smbfs`.

## Global Constraints

- Only SMB changes. AFP and WebDAV continue through `mountNetFS` (`NetFSMountURLSync`) unchanged. NFS unchanged.
- Credentials go in the mount URL as `smb://<enc(user)>:<enc(password)>@host/share`; `enc()` percent-encodes unconditionally (any special char). No credentials in URL when username is empty.
- Mount command runs via `Process.arguments` array (never a shell string). URL is a single argument.
- Reuse existing `netFSMountTimeout` + one-shot `wrappedCompletion` lock release. On timeout, `process.terminate()` the subprocess.
- Reuse existing `config.isValidMountTarget` guard and `MountError.isNonRetryable` classification.
- Remove the temporary `[diag]` logging lines added during debugging.
- `mount_smbfs` creates the `/Volumes/<share>` mount point itself as the current user — no root/osascript, no manual mkdir.

## Working Tree Note

The working tree currently has uncommitted changes from debugging: `[diag]` logging in `MountingManager.swift`, a `mountURLString` addition in `ServerConfig.swift`, and a `mountURLString` test. These are superseded by this plan. Task 1 folds them in: keep `mountURLString` (still used by AFP/WebDAV via `mountNetFS`), delete the `[diag]` lines.

---

### Task 1: Remove diagnostic logging, keep NetFS path clean for AFP/WebDAV

**Files:**
- Modify: `NetMounter/Sources/NetMounter/Services/MountingManager.swift` (the `defaultNetFSMount` closure with `[diag]` lines)

**Interfaces:**
- Consumes: nothing new.
- Produces: a clean `mountNetFS`/`defaultNetFSMount` used by AFP/WebDAV only after Task 2.

- [ ] **Step 1: Delete the two `[diag]` log lines**

In `defaultNetFSMount`, remove:
```swift
logger.debug("[diag] NetFS CALL url=\(url.absoluteString) user=\(user ?? "<nil>") hasPassword=\(password != nil)")
```
and
```swift
logger.debug("[diag] NetFS RETURN url=\(url.absoluteString) result=\(result)")
```
Leave the rest of the closure intact.

- [ ] **Step 2: Build to verify it compiles**

Run: `cd NetMounter && swift build`
Expected: `Build complete!`

- [ ] **Step 3: Run tests (no behavior change expected)**

Run: `cd NetMounter && swift test`
Expected: 32 tests pass, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add NetMounter/Sources/NetMounter/Services/MountingManager.swift NetMounter/Sources/NetMounter/Models/ServerConfig.swift NetMounter/Tests/NetMounterTests/MountingManagerTests.swift
git commit -m "chore: remove temporary NetFS diagnostic logging"
```
(This also commits the pending `mountURLString` addition + its test from the prior debugging round, which AFP/WebDAV still use.)

---

### Task 2: SMB credential URL builder (percent-encoded)

**Files:**
- Modify: `NetMounter/Sources/NetMounter/Models/ServerConfig.swift`
- Test: `NetMounter/Tests/NetMounterTests/MountingManagerTests.swift`

**Interfaces:**
- Consumes: `hostname`, `username`, `normalizedSharePath`, `serverProtocol.scheme`.
- Produces:
  - `func smbMountURLString(password: String?) -> String` on `ServerConfig` — returns `smb://<enc(user)>:<enc(pass)>@host/share`, or `smb://host/share` when username is empty. `enc()` percent-encodes with a strict allowed set (`.alphanumerics`). Password nil/empty → omit `:password`. Username empty → omit userinfo entirely.

- [ ] **Step 1: Write the failing tests**

```swift
func testSMBMountURL_noCredentials() {
    let c = ServerConfig(alias: "n", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "media")
    XCTAssertEqual(c.smbMountURLString(password: nil), "smb://192.168.1.2/media")
}

func testSMBMountURL_userAndPassword_plain() {
    var c = ServerConfig(alias: "n", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "media")
    c.username = "jasine"
    XCTAssertEqual(c.smbMountURLString(password: "secret"), "smb://jasine:secret@192.168.1.2/media")
}

func testSMBMountURL_specialCharsPercentEncoded() {
    var c = ServerConfig(alias: "n", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "media")
    c.username = "user@dom"
    // "@", ":", "/", " " must be percent-encoded so the URL parses correctly.
    XCTAssertEqual(c.smbMountURLString(password: "p@ss:w/ d"),
                   "smb://user%40dom:p%40ss%3Aw%2F%20d@192.168.1.2/media")
}

func testSMBMountURL_usernameSetButPasswordEmpty_omitsColon() {
    var c = ServerConfig(alias: "n", serverProtocol: .smb, hostname: "192.168.1.2", sharePath: "media")
    c.username = "jasine"
    XCTAssertEqual(c.smbMountURLString(password: nil), "smb://jasine@192.168.1.2/media")
    XCTAssertEqual(c.smbMountURLString(password: ""), "smb://jasine@192.168.1.2/media")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd NetMounter && swift test --filter MountingManagerTests`
Expected: FAIL — `smbMountURLString` not found.

- [ ] **Step 3: Implement**

Add to `ServerConfig`:
```swift
/// Mount URL for SMB, credentials embedded and percent-encoded so any
/// special characters parse correctly. Used only to invoke mount_smbfs;
/// not for display (see urlString). Password nil/empty omits ":password";
/// empty username omits the userinfo entirely.
func smbMountURLString(password: String?) -> String {
    let share = normalizedSharePath
    let host = hostname
    guard let user = username, !user.isEmpty else {
        return "smb://\(host)/\(share)"
    }
    func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
    let userInfo: String
    if let pw = password, !pw.isEmpty {
        userInfo = "\(enc(user)):\(enc(pw))"
    } else {
        userInfo = enc(user)
    }
    return "smb://\(userInfo)@\(host)/\(share)"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd NetMounter && swift test --filter MountingManagerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add NetMounter/Sources/NetMounter/Models/ServerConfig.swift NetMounter/Tests/NetMounterTests/MountingManagerTests.swift
git commit -m "feat: add percent-encoded SMB mount URL builder"
```

---

### Task 3: Route SMB mounts through a mount_smbfs subprocess

**Files:**
- Modify: `NetMounter/Sources/NetMounter/Services/MountingManager.swift`
- Test: `NetMounter/Tests/NetMounterTests/MountingManagerTests.swift`

**Interfaces:**
- Consumes: `ServerConfig.smbMountURLString(password:)` (Task 2), `config.isValidMountTarget`, `markInflight`/`clearInflight`, `netFSMountTimeout`, `MountError`.
- Produces:
  - `mount(config:)` dispatches `.smb` → new `mountSMB(config:completion:)`; `.afp`/`.webdav` → existing `mountNetFS`; `.nfs` → existing `mountNFS`.
  - `mountSMB` runs the mount via an injectable seam `performSMBMount: ((_ url: String, _ mountPoint: String, _ completion: @escaping (Int32, String) -> Void) -> Void)?` (status code + stderr). Default runs `/sbin/mount_smbfs`.

**Context:** No real mount in unit tests — the injectable seam lets us test the lock/timeout/error-mapping without a network. Real mounting is verified manually (Task 4).

- [ ] **Step 1: Write the failing tests**

```swift
func testMountSMB_success_releasesLockAndReturnsPath() {
    let mgr = MountingManager.shared
    let config = ServerConfig(alias: "smb-ok", serverProtocol: .smb, hostname: "10.0.0.20", sharePath: "media")
    mgr.performSMBMount = { _, mountPoint, completion in completion(0, "") }
    let exp = expectation(description: "done")
    var received: Result<String, Error>?
    mgr.mount(config: config) { received = $0; exp.fulfill() }
    wait(for: [exp], timeout: 2)
    if case .success = received {} else { XCTFail("expected success") }
    XCTAssertFalse(mgr.isMountInFlight(config.id))
    mgr.performSMBMount = nil
}

func testMountSMB_authFailure_mapsToNonRetryable() {
    let mgr = MountingManager.shared
    let config = ServerConfig(alias: "smb-auth", serverProtocol: .smb, hostname: "10.0.0.21", sharePath: "media")
    // mount_smbfs exit 77 (EAUTH) with an "Authentication error" stderr.
    mgr.performSMBMount = { _, _, completion in completion(77, "mount_smbfs: server rejected the authentication: Authentication error") }
    let exp = expectation(description: "done")
    var received: Result<String, Error>?
    mgr.mount(config: config) { received = $0; exp.fulfill() }
    wait(for: [exp], timeout: 2)
    guard case .failure(let err) = received, let me = err as? MountError else {
        XCTFail("expected MountError failure"); return
    }
    XCTAssertTrue(me.isNonRetryable, "auth failure must not be retried")
    XCTAssertFalse(mgr.isMountInFlight(config.id))
    mgr.performSMBMount = nil
}

func testMountSMB_emptyShare_failsFastWithoutLock() {
    let mgr = MountingManager.shared
    let config = ServerConfig(alias: "smb-empty", serverProtocol: .smb, hostname: "10.0.0.22", sharePath: "")
    let exp = expectation(description: "done")
    var received: Result<String, Error>?
    mgr.mount(config: config) { received = $0; exp.fulfill() }
    wait(for: [exp], timeout: 2)
    if case .failure = received {} else { XCTFail("expected failure") }
    XCTAssertFalse(mgr.isMountInFlight(config.id))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd NetMounter && swift test --filter MountingManagerTests`
Expected: FAIL — `performSMBMount` not found / SMB still routes to NetFS.

- [ ] **Step 3: Implement dispatch + mountSMB**

In `mount(config:)`:
```swift
func mount(config: ServerConfig, silent: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
    switch config.serverProtocol {
    case .nfs:
        mountNFS(config: config, silent: silent, completion: completion)
    case .smb:
        mountSMB(config: config, completion: completion)
    case .afp, .webdav:
        mountNetFS(config: config, silent: silent, completion: completion)
    }
}
```

Add the injectable seam near `performNetFSMount`:
```swift
/// The low-level SMB mount, injectable for testing. Default runs
/// /sbin/mount_smbfs. Completion: (exitStatus, stderr).
var performSMBMount: ((String, String, @escaping (Int32, String) -> Void) -> Void)?
```

Add `mountSMB`:
```swift
private func mountSMB(config: ServerConfig, completion: @escaping (Result<String, Error>) -> Void) {
    guard config.isValidMountTarget else {
        DispatchQueue.main.async { completion(.failure(MountError.invalidShare)) }
        return
    }
    guard markInflight(config.id) else {
        logger.debug("Mount already in-flight for \(config.alias), skipping")
        DispatchQueue.main.async { completion(.failure(MountError.mountFailed(EBUSY))) }
        return
    }

    let didComplete = NSLock()
    var completed = false
    let wrappedCompletion: (Result<String, Error>) -> Void = { [weak self] result in
        didComplete.lock()
        if completed { didComplete.unlock(); return }
        completed = true
        didComplete.unlock()
        self?.clearInflight(config.id)
        DispatchQueue.main.async { completion(result) }
    }

    let mountPoint = "/Volumes/\(config.normalizedSharePath.components(separatedBy: "/").last ?? config.normalizedSharePath)"

    // Already mounted and alive?
    if let url = URL(string: config.mountURLString), let existing = findExistingMountPath(for: url) {
        if isMountAlive(existing) { wrappedCompletion(.success(existing)); return }
        else { forceUnmount(path: existing) }
    }

    let password: String? = {
        guard let keyId = config.keychainItemId else { return nil }
        return KeychainManager.shared.retrievePassword(for: keyId)
    }()
    let mountURL = config.smbMountURLString(password: password)

    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + netFSMountTimeout) {
        wrappedCompletion(.failure(MountError.timedOut))
    }

    let mountFn = performSMBMount ?? Self.defaultSMBMount
    mountFn(mountURL, mountPoint) { status, stderr in
        if status == 0 {
            wrappedCompletion(.success(mountPoint))
        } else if stderr.localizedCaseInsensitiveContains("authentication") {
            wrappedCompletion(.failure(MountError.authenticationFailed))
        } else {
            logger.error("mount_smbfs failed (\(status)): \(stderr)")
            wrappedCompletion(.failure(MountError.mountFailed(status)))
        }
    }
}

/// Production SMB mount via /sbin/mount_smbfs. Runs the URL + mountpoint as
/// arguments (no shell). Terminates the process if it outlives the timeout.
private static let defaultSMBMount: (String, String, @escaping (Int32, String) -> Void) -> Void = { url, mountPoint, completion in
    DispatchQueue.global(qos: .userInitiated).async {
        // mount_smbfs creates the mount point itself, but ensure /Volumes child exists.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount_smbfs")
        process.arguments = [url, mountPoint]
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            completion(-1, error.localizedDescription)
            return
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        completion(process.terminationStatus, stderr)
    }
}
```

Note: `mount_smbfs` requires the mount point to exist. It does NOT auto-create `/Volumes/<share>`. Prepend, inside `defaultSMBMount` before `process.run()`:
```swift
try? FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
```
(Current user can create dirs under `/Volumes` — verified: native `mount_smbfs` to `/tmp` worked as the user; `/Volumes` child creation likewise succeeds for the console user.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd NetMounter && swift test --filter MountingManagerTests`
Expected: PASS.

- [ ] **Step 5: Run full suite**

Run: `cd NetMounter && swift test`
Expected: all pass, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add NetMounter/Sources/NetMounter/Services/MountingManager.swift NetMounter/Tests/NetMounterTests/MountingManagerTests.swift
git commit -m "feat: mount SMB via mount_smbfs subprocess instead of NetFSMountURLSync"
```

---

### Task 4: Manual integration verification (human)

**Files:** none.

**Context:** Requires the real NAS (192.168.1.2), credentials, and the NAS not being in an auto-blocked state. Automated tests can't exercise the real mount.

- [ ] **Step 1: Clean slate**

Run:
```bash
diskutil unmount force /Volumes/media 2>/dev/null; true
```

- [ ] **Step 2: Build and run**

Run: `cd NetMounter && make run`

- [ ] **Step 3: Configure and mount SMB `media` with correct credentials**

In the app, ensure the `media` SMB server has hostname `192.168.1.2`, share `media`, username `jasine`, correct password. Trigger a mount.

- [ ] **Step 4: Verify success**

Run:
```bash
tail -20 ~/Library/Logs/NetMounter/netmounter.log
mount | grep -i media
```
Expected: mount succeeds within a second or two (NOT a 30s timeout); `//...@192.168.1.2/media on /Volumes/media (smbfs ...)`; log shows a success, not repeated error 16.

- [ ] **Step 5: Verify clean failure on wrong password**

Change the password to a wrong value, remount.
Expected: fails promptly with an auth error, no 30s hang, no infinite retry loop (log: "Cannot mount ... skipping retries").

- [ ] **Step 6: Record results in the PR description.**

---

## Self-Review

**1. Spec coverage:**
- SMB → mount_smbfs subprocess → Task 3. ✓
- AFP/WebDAV stay on NetFS → Task 3 dispatch keeps `.afp`/`.webdav` on `mountNetFS`. ✓
- Credentials in percent-encoded URL → Task 2. ✓
- Args array, no shell → Task 3 `defaultSMBMount` uses `process.arguments`. ✓
- Reuse timeout + one-shot lock + isValidMountTarget + isNonRetryable → Task 3. ✓
- Remove [diag] logging → Task 1. ✓
- mount_smbfs mount point creation → Task 3 Step 3 note (createDirectory). ✓
- Manual verification → Task 4. ✓

**2. Placeholder scan:** No TBD/TODO; all code shown; commands have expected output. ✓

**3. Type consistency:** `smbMountURLString(password:)`, `performSMBMount: (String, String, @escaping (Int32, String) -> Void)?`, `defaultSMBMount`, `mountSMB(config:completion:)`, `MountError.authenticationFailed`/`.invalidShare`/`.timedOut`/`.mountFailed` — consistent across Tasks 2–3. ✓

**Correction applied during review:** initial spec said mount_smbfs auto-creates the mount point; corrected in Task 3 to explicitly `createDirectory` first, since mount_smbfs requires an existing mount point.
