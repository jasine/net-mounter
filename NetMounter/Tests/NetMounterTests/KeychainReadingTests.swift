import Security
import XCTest
@testable import NetMounter

final class KeychainReadingTests: XCTestCase {
    func testReadPreservesKeychainFailureStatus() {
        let manager = KeychainManager()
        manager.copyPasswordItem = { _ in (errSecUserCanceled, nil) }
        XCTAssertEqual(manager.readPassword(for: "fixture"), .failure(.status(errSecUserCanceled)))
    }

    func testReadRejectsInvalidPasswordData() {
        let manager = KeychainManager()
        manager.copyPasswordItem = { _ in (errSecSuccess, Data([0xff]) as NSData) }
        XCTAssertEqual(manager.readPassword(for: "fixture"), .failure(.status(errSecDecode)))
    }

    func testReadReturnsPasswordWithoutChangingStoredItem() {
        let manager = KeychainManager()
        manager.copyPasswordItem = { query in
            let values = query as NSDictionary
            XCTAssertEqual(values[kSecAttrService] as? String, "com.netmounter.service")
            XCTAssertEqual(values[kSecAttrAccount] as? String, "fixture")
            return (errSecSuccess, Data("test-password".utf8) as NSData)
        }
        XCTAssertEqual(manager.readPassword(for: "fixture"), .success("test-password"))
    }
}
