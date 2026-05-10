import XCTest
@testable import NetMounter

final class MountSnapshotTests: XCTestCase {

    func testMatchesServerConfig_sameHostAndShare() {
        let snapshot = MountSnapshot(
            serverID: nil,
            volumePath: "/Volumes/shared",
            remountURL: URL(string: "smb://192.168.1.100/shared")!
        )
        let config = ServerConfig(
            alias: "NAS",
            serverProtocol: .smb,
            hostname: "192.168.1.100",
            sharePath: "shared"
        )
        XCTAssertTrue(snapshot.matches(config))
    }

    func testMatchesServerConfig_differentHost() {
        let snapshot = MountSnapshot(
            serverID: nil,
            volumePath: "/Volumes/shared",
            remountURL: URL(string: "smb://10.0.0.5/shared")!
        )
        let config = ServerConfig(
            alias: "NAS",
            serverProtocol: .smb,
            hostname: "192.168.1.100",
            sharePath: "shared"
        )
        XCTAssertFalse(snapshot.matches(config))
    }

    func testMatchesServerConfig_caseInsensitiveHost() {
        let snapshot = MountSnapshot(
            serverID: nil,
            volumePath: "/Volumes/docs",
            remountURL: URL(string: "smb://MyNAS.local/docs")!
        )
        let config = ServerConfig(
            alias: "NAS",
            serverProtocol: .smb,
            hostname: "mynas.local",
            sharePath: "docs"
        )
        XCTAssertTrue(snapshot.matches(config))
    }

    func testMatchesServerConfig_differentShare() {
        let snapshot = MountSnapshot(
            serverID: nil,
            volumePath: "/Volumes/photos",
            remountURL: URL(string: "smb://192.168.1.100/photos")!
        )
        let config = ServerConfig(
            alias: "NAS",
            serverProtocol: .smb,
            hostname: "192.168.1.100",
            sharePath: "documents"
        )
        XCTAssertFalse(snapshot.matches(config))
    }
}
