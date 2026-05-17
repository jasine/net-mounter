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
        guard let arpPath = NetworkMonitor.resolveCommand(["/usr/sbin/arp", "/sbin/arp"]) else { return nil }

        let output = NetworkMonitor.runCommand(arpPath, arguments: ["-n", hostname])
        guard let line = output.components(separatedBy: "\n")
            .first(where: { $0.contains("(\(hostname))") }) else { return nil }

        return NetworkMonitor.parseMACFromARPLine(line)
    }
}
