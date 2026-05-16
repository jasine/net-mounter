# Wake-on-LAN Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Wake-on-LAN support so NetMounter automatically wakes sleeping NAS devices before mounting shares — triggered on lid open, network change, and health check.

**Architecture:** WOL is a best-effort pre-mount step integrated into the existing `AutoMountService.attemptMount` flow. A new stateless `WOLService` handles magic packet construction/sending and MAC resolution via ARP. MAC addresses are auto-learned when servers are first reachable. The UI adds a WOL section to `ServerDetailView`.

**Tech Stack:** Swift 5.10, SwiftUI, Network.framework (`NWConnection` UDP), `arp` CLI for MAC resolution

**Spec:** `docs/superpowers/specs/2026-05-17-wake-on-lan-design.md`

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `Sources/NetMounter/Models/ServerConfig.swift` | Modify | Add 4 WOL fields to `ServerConfig` |
| `Sources/NetMounter/Services/WOLService.swift` | Create | Magic packet send + MAC resolution |
| `Sources/NetMounter/Services/AutoMountService.swift` | Modify | WOL branch in `attemptMount`, hostname dedup, poll loop |
| `Sources/NetMounter/Services/NotificationService.swift` | Modify | Add `notifyWOLFailed` |
| `Sources/NetMounter/Views/ServerDetailView.swift` | Modify | Add WOL config section |
| `Tests/NetMounterTests/WOLServiceTests.swift` | Create | Unit tests for magic packet + MAC validation |

---

### Task 1: Add WOL Fields to ServerConfig

**Files:**
- Modify: `Sources/NetMounter/Models/ServerConfig.swift:57-86`
- Test: `Tests/NetMounterTests/WOLServiceTests.swift` (created in Task 2)

- [ ] **Step 1: Add WOL fields to ServerConfig**

Add these fields after the `pinnedFolders` property (line 69):

```swift
struct ServerConfig: Codable, Identifiable {
    var id: UUID = UUID()
    var alias: String
    var serverProtocol: NetworkProtocol = .smb
    var hostname: String
    var sharePath: String
    var username: String?
    var keychainItemId: String?
    
    // Auto-mount rules
    var autoMountRules: [AutoMountRule] = []
    var pinnedFolders: [PinnedFolder] = []

    // Wake-on-LAN
    var wolEnabled: Bool = false
    var wolMACAddress: String?
    var wolBroadcastAddress: String?
    var wolPort: UInt16 = 9

    // ... rest unchanged ...
}
```

- [ ] **Step 2: Build to verify no compilation errors**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift build 2>&1 | tail -5`
Expected: `Build complete!`

Since `ServerConfig` is `Codable` and all new fields have defaults, existing serialized configs will decode without issues (new fields get their default values).

- [ ] **Step 3: Commit**

```bash
git add Sources/NetMounter/Models/ServerConfig.swift
git commit -m "feat(wol): add WOL fields to ServerConfig"
```

---

### Task 2: Create WOLService — Magic Packet

**Files:**
- Create: `Sources/NetMounter/Services/WOLService.swift`
- Create: `Tests/NetMounterTests/WOLServiceTests.swift`

- [ ] **Step 1: Write failing tests for MAC parsing and magic packet construction**

Create `Tests/NetMounterTests/WOLServiceTests.swift`:

```swift
import XCTest
@testable import NetMounter

final class WOLServiceTests: XCTestCase {

    // MARK: - MAC Parsing

    func testParseMACAddress_colonSeparated() throws {
        let bytes = try WOLService.parseMACAddress("AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(bytes, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    func testParseMACAddress_dashSeparated() throws {
        let bytes = try WOLService.parseMACAddress("AA-BB-CC-DD-EE-FF")
        XCTAssertEqual(bytes, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    func testParseMACAddress_lowercase() throws {
        let bytes = try WOLService.parseMACAddress("aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(bytes, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
    }

    func testParseMACAddress_invalidLength() {
        XCTAssertThrowsError(try WOLService.parseMACAddress("AA:BB:CC"))
    }

    func testParseMACAddress_invalidHex() {
        XCTAssertThrowsError(try WOLService.parseMACAddress("GG:HH:II:JJ:KK:LL"))
    }

    func testParseMACAddress_empty() {
        XCTAssertThrowsError(try WOLService.parseMACAddress(""))
    }

    // MARK: - Magic Packet

    func testBuildMagicPacket_length() throws {
        let packet = try WOLService.buildMagicPacket(macAddress: "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(packet.count, 102)
    }

    func testBuildMagicPacket_header() throws {
        let packet = try WOLService.buildMagicPacket(macAddress: "AA:BB:CC:DD:EE:FF")
        let header = Array(packet.prefix(6))
        XCTAssertEqual(header, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    func testBuildMagicPacket_macRepeated16Times() throws {
        let mac: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        let packet = try WOLService.buildMagicPacket(macAddress: "AA:BB:CC:DD:EE:FF")
        let payload = Array(packet.dropFirst(6))
        XCTAssertEqual(payload.count, 96)
        for i in 0..<16 {
            let chunk = Array(payload[i*6..<(i+1)*6])
            XCTAssertEqual(chunk, mac, "MAC mismatch at repetition \(i)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift test --filter WOLServiceTests 2>&1 | tail -10`
Expected: Compilation error — `WOLService` not defined.

- [ ] **Step 3: Implement WOLService**

Create `Sources/NetMounter/Services/WOLService.swift`:

```swift
import Foundation
import Network
import Logging

private let logger = Logger(label: "WOL")

enum WOLError: LocalizedError {
    case invalidMACAddress(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidMACAddress(let mac): return "Invalid MAC address: \(mac)"
        case .sendFailed(let reason): return "WOL send failed: \(reason)"
        }
    }
}

class WOLService {
    static let shared = WOLService()

    // MARK: - MAC Parsing

    static func parseMACAddress(_ mac: String) throws -> [UInt8] {
        let cleaned = mac.replacingOccurrences(of: "-", with: ":")
        let parts = cleaned.split(separator: ":")
        guard parts.count == 6 else {
            throw WOLError.invalidMACAddress(mac)
        }
        var bytes: [UInt8] = []
        for part in parts {
            guard let byte = UInt8(part, radix: 16) else {
                throw WOLError.invalidMACAddress(mac)
            }
            bytes.append(byte)
        }
        return bytes
    }

    // MARK: - Magic Packet

    static func buildMagicPacket(macAddress: String) throws -> Data {
        let macBytes = try parseMACAddress(macAddress)
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }
        return packet
    }

    // MARK: - Send

    func wake(macAddress: String,
              broadcastAddress: String = "255.255.255.255",
              port: UInt16 = 9) throws {
        let packet = try Self.buildMagicPacket(macAddress: macAddress)

        let host = NWEndpoint.Host(broadcastAddress)
        let nwPort = NWEndpoint.Port(integerLiteral: port)

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .other

        let connection = NWConnection(host: host, port: nwPort, using: params)

        let semaphore = DispatchSemaphore(value: 0)
        var sendError: Error?

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: packet, completion: .contentProcessed { error in
                    sendError = error
                    connection.cancel()
                    semaphore.signal()
                })
            case .failed(let error):
                sendError = error
                semaphore.signal()
            case .cancelled:
                break
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))

        let result = semaphore.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            connection.cancel()
            throw WOLError.sendFailed("Timeout sending magic packet")
        }
        if let error = sendError {
            throw WOLError.sendFailed(error.localizedDescription)
        }

        logger.info("WOL magic packet sent to \(macAddress) via \(broadcastAddress):\(port)")
    }

    // MARK: - MAC Resolution

    func resolveMAC(for hostname: String) -> String? {
        guard let arpPath = ["/usr/sbin/arp", "/sbin/arp"]
            .first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }

        let output = Self.runCommand(arpPath, arguments: ["-n", hostname])
        guard let line = output.components(separatedBy: "\n")
            .first(where: { $0.contains(hostname) || $0.contains("(") }) else { return nil }

        let parts = line.components(separatedBy: " ")
        if let atIndex = parts.firstIndex(of: "at"), atIndex + 1 < parts.count {
            let mac = parts[atIndex + 1]
            if mac.contains(":") && mac != "(incomplete)" {
                return mac
            }
        }
        return nil
    }

    private static func runCommand(_ path: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift test --filter WOLServiceTests 2>&1 | tail -10`
Expected: All 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/NetMounter/Services/WOLService.swift Tests/NetMounterTests/WOLServiceTests.swift
git commit -m "feat(wol): add WOLService with magic packet and MAC resolution"
```

---

### Task 3: Add WOL Notification

**Files:**
- Modify: `Sources/NetMounter/Services/NotificationService.swift:52-78`

- [ ] **Step 1: Add `notifyWOLFailed` method**

Add after the `notifyZombieHealed` method (after line 71):

```swift
func notifyWOLFailed(server: ServerConfig) {
    send(id: "wol-failed-\(server.id)",
         title: String(localized: "Wake Failed"),
         body: String(localized: "Could not wake \(server.alias). Check if WOL is enabled on the device."))
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/NetMounter/Services/NotificationService.swift
git commit -m "feat(wol): add WOL failure notification"
```

---

### Task 4: Integrate WOL into AutoMountService

**Files:**
- Modify: `Sources/NetMounter/Services/AutoMountService.swift`

This is the core integration. We add:
1. A `wolPendingServers` dictionary for hostname deduplication
2. A WOL branch in `attemptMount` when server is unreachable + WOL enabled
3. A polling loop that checks reachability every 3s for up to 60s
4. MAC auto-learning on successful mount

- [ ] **Step 1: Add WOL dedup state and MAC learning helper**

Add a new property after `lastEvaluation` (line 19) in `AutoMountService`:

```swift
// Track WOL polling per hostname to avoid duplicate magic packets
private var wolPendingServers: [String: [ServerConfig]] = [:]
private var wolPollTimers: [String: DispatchWorkItem] = [:]
```

- [ ] **Step 2: Add MAC auto-learning helper method**

Add this private method at the end of the class (before the closing brace):

```swift
private func learnMACIfNeeded(for server: ServerConfig) {
    guard server.wolMACAddress == nil else { return }
    DispatchQueue.global(qos: .utility).async { [weak self] in
        guard let mac = WOLService.shared.resolveMAC(for: server.hostname) else { return }
        DispatchQueue.main.async {
            guard let self = self else { return }
            if var updated = self.appState.servers.first(where: { $0.id == server.id }),
               updated.wolMACAddress == nil {
                updated.wolMACAddress = mac
                self.appState.updateServer(updated)
                logger.info("Auto-learned MAC \(mac) for \(server.alias)")
            }
        }
    }
}
```

- [ ] **Step 3: Add WOL wake-and-poll method**

Add this private method after `learnMACIfNeeded`:

```swift
private func attemptWOLAndPoll(_ server: ServerConfig) {
    let hostname = server.hostname

    // Dedup: if already polling this hostname, queue the server
    if wolPendingServers[hostname] != nil {
        wolPendingServers[hostname]?.append(server)
        logger.debug("WOL poll already active for \(hostname), queued \(server.alias)")
        return
    }

    // First server for this hostname — send WOL and start polling
    wolPendingServers[hostname] = [server]

    guard let mac = server.wolMACAddress else {
        logger.warning("WOL enabled but no MAC for \(server.alias), skipping")
        drainWOLQueue(hostname: hostname, reachable: false)
        return
    }

    do {
        try WOLService.shared.wake(
            macAddress: mac,
            broadcastAddress: server.wolBroadcastAddress ?? "255.255.255.255",
            port: server.wolPort
        )
        logger.info("WOL sent for \(server.alias) (\(mac))")
    } catch {
        logger.error("WOL failed for \(server.alias): \(error.localizedDescription)")
        drainWOLQueue(hostname: hostname, reachable: false)
        return
    }

    // Start polling every 3s, timeout 60s
    pollReachability(hostname: hostname, port: server.serverProtocol.defaultPort,
                     interval: 3.0, remaining: 60.0)
}

private func pollReachability(hostname: String, port: UInt16,
                              interval: TimeInterval, remaining: TimeInterval) {
    guard remaining > 0 else {
        logger.warning("WOL poll timeout for \(hostname)")
        if let servers = wolPendingServers[hostname] {
            for s in servers {
                NotificationService.shared.notifyWOLFailed(server: s)
            }
        }
        drainWOLQueue(hostname: hostname, reachable: false)
        return
    }

    let work = DispatchWorkItem { [weak self] in
        ConnectionTester.shared.checkReachability(host: hostname, port: port) { result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(true):
                    logger.info("\(hostname) became reachable after WOL")
                    self.drainWOLQueue(hostname: hostname, reachable: true)
                case .success(false), .failure:
                    self.pollReachability(hostname: hostname, port: port,
                                         interval: interval, remaining: remaining - interval)
                }
            }
        }
    }
    wolPollTimers[hostname] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
}

private func drainWOLQueue(hostname: String, reachable: Bool) {
    let servers = wolPendingServers.removeValue(forKey: hostname) ?? []
    wolPollTimers.removeValue(forKey: hostname)

    if reachable {
        for server in servers {
            attemptMount(server, retryCount: 0)
        }
    } else {
        for server in servers {
            scheduleRetry(for: server, currentRetryCount: 0)
        }
    }
}
```

- [ ] **Step 4: Modify `attemptMount` to call WOL when unreachable**

Replace the `case .success(false), .failure:` branch inside `attemptMount` (currently line 168-169):

Current code:
```swift
case .success(false), .failure:
    logger.debug("\(server.hostname) not reachable. Skipping.")
    self?.scheduleRetry(for: server, currentRetryCount: retryCount)
```

New code:
```swift
case .success(false), .failure:
    logger.debug("\(server.hostname) not reachable.")
    if retryCount == 0 && server.wolEnabled && server.wolMACAddress != nil {
        self?.attemptWOLAndPoll(server)
    } else {
        self?.scheduleRetry(for: server, currentRetryCount: retryCount)
    }
```

- [ ] **Step 5: Add MAC learning call on successful mount**

In `attemptMount`, after the `logger.info("Mounted \(server.alias) at \(path)")` line (around line 159), add:

```swift
self?.learnMACIfNeeded(for: server)
```

So the success block becomes:
```swift
case .success(let path):
    logger.info("Mounted \(server.alias) at \(path)")
    NotificationService.shared.notifyMountSucceeded(server: server)
    self?.learnMACIfNeeded(for: server)
    onSuccess?()
```

- [ ] **Step 6: Cancel WOL polls on network change**

In `cancelAllRetries()`, add cleanup for WOL state:

```swift
private func cancelAllRetries() {
    for item in retryWorkItems.values {
        item.cancel()
    }
    retryWorkItems.removeAll()

    // Cancel any active WOL polls
    for item in wolPollTimers.values {
        item.cancel()
    }
    wolPollTimers.removeAll()
    wolPendingServers.removeAll()
}
```

- [ ] **Step 7: Build to verify compilation**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 8: Run full test suite**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift test 2>&1 | tail -10`
Expected: All tests pass (existing tests + new WOLServiceTests).

- [ ] **Step 9: Commit**

```bash
git add Sources/NetMounter/Services/AutoMountService.swift
git commit -m "feat(wol): integrate WOL into auto-mount flow with poll and dedup"
```

---

### Task 5: Add WOL Section to ServerDetailView

**Files:**
- Modify: `Sources/NetMounter/Views/ServerDetailView.swift`

- [ ] **Step 1: Add WOL section to the form**

After the Auto-Mount `Section` block (after line 109's closing brace `}`), add:

```swift
if !isNew {
    Section(header: Text("Wake-on-LAN").foregroundColor(.secondary)) {
        Toggle("Wake before mount", isOn: $config.wolEnabled)
            .toggleStyle(.switch)
            .disabled(config.wolMACAddress == nil)

        if config.wolMACAddress == nil {
            Text("Connect to server once to detect MAC address.")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        if config.wolMACAddress != nil {
            TextField("MAC Address", text: Binding(
                get: { config.wolMACAddress ?? "" },
                set: { config.wolMACAddress = $0.isEmpty ? nil : $0 }
            ))

            DisclosureGroup("Advanced") {
                TextField("Broadcast Address", text: Binding(
                    get: { config.wolBroadcastAddress ?? "255.255.255.255" },
                    set: { config.wolBroadcastAddress = ($0 == "255.255.255.255" || $0.isEmpty) ? nil : $0 }
                ))
                TextField("Port", value: $config.wolPort, format: .number)
            }
        }
    }
}
```

The `if !isNew` guard ensures WOL options only show when editing an existing server (MAC can't be detected until the server has been connected to at least once).

- [ ] **Step 2: Add MAC learning on successful Test Connection**

In the `testConnection()` method, inside the `case .success(true):` branch (around line 161), add MAC resolution after setting the result:

```swift
case .success(true):
    testResult = true
    // Auto-learn MAC address for WOL
    if config.wolMACAddress == nil {
        DispatchQueue.global(qos: .utility).async {
            if let mac = WOLService.shared.resolveMAC(for: self.config.hostname) {
                DispatchQueue.main.async {
                    self.config.wolMACAddress = mac
                }
            }
        }
    }
```

- [ ] **Step 3: Build to verify**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 4: Run full test suite**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift test 2>&1 | tail -10`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/NetMounter/Views/ServerDetailView.swift
git commit -m "feat(wol): add WOL configuration section to server detail view"
```

---

### Task 6: Manual End-to-End Verification

- [ ] **Step 1: Build release binary**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift build -c release 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 2: Verify checklist**

Verify these manually:

1. Open app → add/edit a server → WOL section is visible (for existing servers only)
2. WOL toggle is disabled when MAC is not yet detected, with helper text
3. Click "Test Connection" on a reachable server → MAC address auto-populates
4. WOL toggle becomes enabled after MAC is learned
5. Advanced disclosure group shows broadcast address and port fields
6. Save → reopen → WOL settings persist (JSON serialization round-trip)

- [ ] **Step 3: Run full test suite one final time**

Run: `cd /Users/chenxinyu.1/Code/net-mounter/NetMounter && swift test 2>&1 | tail -10`
Expected: All tests pass.
