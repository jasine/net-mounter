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
