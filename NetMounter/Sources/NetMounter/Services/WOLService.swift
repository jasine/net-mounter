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
