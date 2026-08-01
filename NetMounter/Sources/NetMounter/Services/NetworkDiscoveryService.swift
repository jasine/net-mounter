import Foundation
import Network
import Combine
import Logging

private let logger = Logger(label: "NetworkDiscovery")

// MARK: - Data Models

struct DiscoveredServer: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let host: String
    let port: UInt16
    let protocolType: NetworkProtocol

    func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(protocolType)
    }

    static func == (lhs: DiscoveredServer, rhs: DiscoveredServer) -> Bool {
        lhs.host == rhs.host && lhs.protocolType == rhs.protocolType
    }
}

struct DiscoveredShare: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let serverID: UUID

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(serverID)
    }

    static func == (lhs: DiscoveredShare, rhs: DiscoveredShare) -> Bool {
        lhs.name == rhs.name && lhs.serverID == rhs.serverID
    }
}

// MARK: - Discovery Service

class NetworkDiscoveryService: ObservableObject {
    @Published var servers: [DiscoveredServer] = []
    @Published var shares: [UUID: [DiscoveredShare]] = [:]
    @Published var isScanning: Bool = false
    @Published var isSubnetScanning: Bool = false
    @Published var isEnumeratingShares: [UUID: Bool] = [:]

    private var smbBrowser: NWBrowser?
    private var afpBrowser: NWBrowser?
    private var nfsBrowser: NWBrowser?
    private let browserQueue = DispatchQueue(label: "NetworkDiscovery.browser")

    // Track pending resolutions to avoid duplicates
    private var pendingResults: [NWBrowser.Result] = []
    private var resolveConnections: [NWConnection] = []

    // Subnet scan state
    private var subnetConnections: [NWConnection] = []
    private var subnetPendingProbes: Int = 0

    func startScan() {
        logger.info("Starting network discovery scan")
        DispatchQueue.main.async {
            self.servers = []
            self.shares = [:]
            self.isScanning = true
        }

        // Browse SMB
        let smbParams = NWParameters()
        smbParams.includePeerToPeer = true
        smbBrowser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: smbParams)
        setupBrowser(smbBrowser!, protocolType: .smb)

        // Browse AFP
        let afpParams = NWParameters()
        afpParams.includePeerToPeer = true
        afpBrowser = NWBrowser(for: .bonjour(type: "_afpovertcp._tcp", domain: nil), using: afpParams)
        setupBrowser(afpBrowser!, protocolType: .afp)

        // Browse NFS
        let nfsParams = NWParameters()
        nfsParams.includePeerToPeer = true
        nfsBrowser = NWBrowser(for: .bonjour(type: "_nfs._tcp", domain: nil), using: nfsParams)
        setupBrowser(nfsBrowser!, protocolType: .nfs)
    }

    func stopScan() {
        logger.info("Stopping network discovery scan")
        smbBrowser?.cancel()
        afpBrowser?.cancel()
        nfsBrowser?.cancel()
        smbBrowser = nil
        afpBrowser = nil
        nfsBrowser = nil

        for conn in resolveConnections {
            conn.cancel()
        }
        resolveConnections.removeAll()
        pendingResults.removeAll()

        DispatchQueue.main.async {
            self.isScanning = false
        }
    }

    // MARK: - Subnet Scan

    /// Probe every host on the local /24 subnet for SMB/AFP/NFS ports.
    /// Complements Bonjour discovery, which only finds hosts that advertise
    /// themselves via mDNS (e.g. Windows shares and manual hosts stay hidden).
    func startSubnetScan() {
        guard !isSubnetScanning else { return }

        guard let prefix = Self.localSubnetPrefix() else {
            logger.warning("Subnet scan: could not determine local IPv4 subnet")
            return
        }

        logger.info("Starting subnet scan on \(prefix).0/24")
        DispatchQueue.main.async {
            self.isSubnetScanning = true
        }

        // (protocol, port) pairs to probe on each host
        let probes: [(NetworkProtocol, UInt16)] = [
            (.smb, 445),
            (.afp, 548),
            (.nfs, 2049),
        ]

        browserQueue.async { [weak self] in
            guard let self = self else { return }
            self.subnetPendingProbes = 254 * probes.count
            for hostByte in 1...254 {
                let host = "\(prefix).\(hostByte)"
                for (proto, port) in probes {
                    self.probeSubnetHost(host: host, port: port, protocolType: proto)
                }
            }
        }
    }

    func stopSubnetScan() {
        browserQueue.async { [weak self] in
            guard let self = self else { return }
            for conn in self.subnetConnections {
                conn.cancel()
            }
            self.subnetConnections.removeAll()
            self.subnetPendingProbes = 0
        }
        DispatchQueue.main.async {
            self.isSubnetScanning = false
        }
    }

    private func probeSubnetHost(host: String, port: UInt16, protocolType: NetworkProtocol) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let server = DiscoveredServer(
                    name: host,
                    host: host,
                    port: port,
                    protocolType: protocolType
                )
                DispatchQueue.main.async {
                    if !self.servers.contains(where: { $0.host == host && $0.protocolType == protocolType }) {
                        self.servers.append(server)
                        logger.info("Subnet scan: found \(protocolType.displayName) on \(host)")
                    }
                }
                connection.cancel()
                self.subnetProbeFinished()
            case .failed, .waiting:
                // Port closed, filtered, or host absent
                connection.cancel()
                self.subnetProbeFinished()
            case .cancelled:
                break
            default:
                break
            }
        }

        browserQueue.async { [weak self] in
            self?.subnetConnections.append(connection)
        }
        connection.start(queue: browserQueue)

        // Timeout: unreachable hosts never reach .failed quickly, so cap the wait.
        browserQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            if connection.state != .cancelled {
                connection.cancel()
                self?.subnetProbeFinished()
            }
        }
    }

    /// Called once per probe when it resolves (ready/failed/timeout). Guarded so
    /// a probe that both fails and times out only decrements once.
    private func subnetProbeFinished() {
        browserQueue.async { [weak self] in
            guard let self = self, self.subnetPendingProbes > 0 else { return }
            self.subnetPendingProbes -= 1
            if self.subnetPendingProbes == 0 {
                DispatchQueue.main.async {
                    self.isSubnetScanning = false
                }
                logger.info("Subnet scan complete")
            }
        }
    }

    /// Determine the local IPv4 /24 prefix (e.g. "192.168.1") from active interfaces.
    private static func localSubnetPrefix() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr {
            let flags = Int32(iface.pointee.ifa_flags)
            let family = iface.pointee.ifa_addr.pointee.sa_family
            // Up, running, not loopback, IPv4
            if (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
               (flags & IFF_LOOPBACK) == 0,
               family == UInt8(AF_INET) {
                let name = String(cString: iface.pointee.ifa_name)
                // Prefer physical/Wi-Fi interfaces; skip VPN/utun (no /24 broadcast domain)
                if name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(iface.pointee.ifa_addr, socklen_t(iface.pointee.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: host)
                    break
                }
            }
            ptr = iface.pointee.ifa_next
        }

        guard let ip = address else { return nil }
        let octets = ip.split(separator: ".")
        guard octets.count == 4 else { return nil }
        return "\(octets[0]).\(octets[1]).\(octets[2])"
    }

    private func setupBrowser(_ browser: NWBrowser, protocolType: NetworkProtocol) {
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.debug("Browser ready for \(protocolType.displayName)")
            case .failed(let error):
                logger.error("Browser failed for \(protocolType.displayName): \(error.localizedDescription)")
            case .cancelled:
                break
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            for change in changes {
                switch change {
                case .added(let result):
                    self.resolveEndpoint(result, protocolType: protocolType)
                case .removed:
                    // Could remove servers, but for a scan session we keep them
                    break
                default:
                    break
                }
            }
        }

        browser.start(queue: browserQueue)
    }

    private func resolveEndpoint(_ result: NWBrowser.Result, protocolType: NetworkProtocol) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }

        // Create a connection to resolve the service endpoint to an actual address
        let connection = NWConnection(to: result.endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                // Extract resolved host from the connection's remote endpoint
                if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = remoteEndpoint {
                    let hostString = self.hostToString(host)
                    let portValue = port.rawValue
                    let server = DiscoveredServer(
                        name: name,
                        host: hostString,
                        port: portValue,
                        protocolType: protocolType
                    )
                    DispatchQueue.main.async {
                        // Deduplicate by host + protocol
                        if !self.servers.contains(where: { $0.host == hostString && $0.protocolType == protocolType }) {
                            self.servers.append(server)
                            logger.info("Discovered \(protocolType.displayName) server: \(name) at \(hostString)")
                        }
                    }
                    // Probe for NFS on the same host (most NAS devices serve both SMB and NFS)
                    if protocolType != .nfs {
                        self.probeNFS(name: name, host: hostString)
                    }
                }
                connection.cancel()
            case .failed:
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }

        resolveConnections.append(connection)
        connection.start(queue: browserQueue)
    }

    private func hostToString(_ host: NWEndpoint.Host) -> String {
        let raw: String
        switch host {
        case .ipv4(let addr):
            raw = "\(addr)"
        case .ipv6(let addr):
            raw = "\(addr)"
        case .name(let name, _):
            raw = name
        @unknown default:
            raw = "\(host)"
        }
        // Strip interface scope suffix (e.g. "192.168.1.2%en0" → "192.168.1.2")
        if let percentIndex = raw.firstIndex(of: "%") {
            return String(raw[raw.startIndex..<percentIndex])
        }
        return raw
    }

    // MARK: - NFS Probe

    /// Probe port 2049 on a discovered host to check if it also serves NFS.
    private func probeNFS(name: String, host: String) {
        // Skip if we already have an NFS entry for this host
        let alreadyKnown = DispatchQueue.main.sync {
            self.servers.contains(where: { $0.host == host && $0.protocolType == .nfs })
        }
        guard !alreadyKnown else { return }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: 2049)
        let connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Port 2049 is open — this host serves NFS
                let server = DiscoveredServer(
                    name: name,
                    host: host,
                    port: 2049,
                    protocolType: .nfs
                )
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if !self.servers.contains(where: { $0.host == host && $0.protocolType == .nfs }) {
                        self.servers.append(server)
                        logger.info("NFS probe: found NFS on \(host)")
                    }
                }
                connection.cancel()
            case .failed, .cancelled:
                connection.cancel()
            case .waiting:
                // Connection can't be established (port filtered/closed)
                connection.cancel()
            default:
                break
            }
        }

        resolveConnections.append(connection)
        connection.start(queue: browserQueue)

        // Timeout: cancel after 3 seconds if no response
        browserQueue.asyncAfter(deadline: .now() + 3) {
            if connection.state != .cancelled {
                connection.cancel()
            }
        }
    }

    // MARK: - Share Enumeration

    func enumerateShares(for server: DiscoveredServer) {
        guard isEnumeratingShares[server.id] != true else { return }

        DispatchQueue.main.async {
            self.isEnumeratingShares[server.id] = true
        }

        NSLog("[Discovery] Enumerating shares on %@ (%@)", server.host, server.name)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let discoveredShares: [DiscoveredShare]

            switch server.protocolType {
            case .smb:
                discoveredShares = self?.enumerateSMBShares(host: server.host, serverID: server.id) ?? []
            case .nfs:
                discoveredShares = self?.enumerateNFSExports(host: server.host, serverID: server.id) ?? []
            case .afp, .webdav:
                discoveredShares = []
            }

            NSLog("[Discovery] Found %d shares on %@", discoveredShares.count, server.host)

            DispatchQueue.main.async {
                self?.shares[server.id] = discoveredShares
                self?.isEnumeratingShares[server.id] = false
            }
        }
    }

    private func enumerateSMBShares(host: String, serverID: UUID) -> [DiscoveredShare] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        process.arguments = ["view", "-G", "-N", "//\(host)"]

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            NSLog("[Discovery] smbutil launch failed: %@", error.localizedDescription)
            return []
        }

        // Read pipe data BEFORE waitUntilExit to avoid deadlock if buffer fills
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        NSLog("[Discovery] smbutil exit=%d host=%@\nSTDOUT:\n%@\nSTDERR:\n%@", process.terminationStatus, host, output, errorOutput)

        // Parse smbutil output. Typical format:
        //     Share           Type       Comment
        //     ------
        //     public          Disk       Public files
        //     IPC$            Pipe       IPC Service
        //     media           Disk
        //
        // Strategy: split each line by 2+ whitespace chars to get columns,
        // then check if any column equals "Disk".
        var shares: [DiscoveredShare] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("Share"), !trimmed.hasPrefix("---") else { continue }

            // Split by runs of 2+ whitespace to separate columns
            let columns = trimmed.components(separatedBy: "  ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            // Need at least name + type
            guard columns.count >= 2 else { continue }

            let shareName = columns[0]
            let shareType = columns[1]

            guard shareType == "Disk" else { continue }
            // Skip hidden shares (ending with $)
            guard !shareName.hasSuffix("$") else { continue }

            shares.append(DiscoveredShare(name: shareName, serverID: serverID))
        }

        return shares
    }

    private func enumerateNFSExports(host: String, serverID: UUID) -> [DiscoveredShare] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/showmount")
        process.arguments = ["-e", host]

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            NSLog("[Discovery] showmount launch failed: %@", error.localizedDescription)
            return []
        }

        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        NSLog("[Discovery] showmount exit=%d host=%@\nSTDOUT:\n%@\nSTDERR:\n%@", process.terminationStatus, host, output, errorOutput)

        // Parse showmount -e output. Typical format:
        //   Exports list on <host>:
        //   /volume1/shared                     192.168.1.0/24
        //   /volume1/media                      (everyone)
        //
        // Lines starting with "/" are exports.
        var shares: [DiscoveredShare] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("/") else { continue }

            // Export path is the first whitespace-delimited token
            let parts = trimmed.components(separatedBy: .whitespaces)
            guard let exportPath = parts.first, !exportPath.isEmpty else { continue }

            shares.append(DiscoveredShare(name: exportPath, serverID: serverID))
        }

        return shares
    }
}
