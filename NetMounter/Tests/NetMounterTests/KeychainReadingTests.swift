import Security
import XCTest
@testable import NetMounter

final class KeychainReadingTests: XCTestCase {
    func testConcurrentReadsSerializeSystemAuthorization() {
        let manager = KeychainManager()
        let lock = NSLock()
        var activeReads = 0
        var maximumReads = 0
        manager.copyPasswordItem = { _ in
            lock.lock()
            activeReads += 1
            maximumReads = max(maximumReads, activeReads)
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.01)
            lock.lock()
            activeReads -= 1
            lock.unlock()
            return (errSecSuccess, Data("fixture-password".utf8) as NSData)
        }
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            XCTAssertEqual(manager.readPassword(for: "fixture"), .success("fixture-password"))
        }
        XCTAssertEqual(maximumReads, 1, "System authorization must not overlap for multiple servers")
    }

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
