import Foundation
import XCTest
@testable import NetMounter

final class PackagingTests: XCTestCase {
    func testPackagingCopiesResourcesAndStripsDebugPathsBeforeSigning() throws {
        let folder = try makeFixture(includeResources: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try runPackaging(in: folder)
        XCTAssertEqual(result.status, 0, result.output)
        let resources = folder.appendingPathComponent("NetMounter.app/Contents/Resources/NetMounter_NetMounter.bundle")
        let bundle = try XCTUnwrap(Bundle(url: resources))
        XCTAssertNotNil(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"))
        XCTAssertNotNil(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "zh-Hans"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("signed-with-resources").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stripped-debug-paths").path))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(".build/apple/Products/Release/NetMounter")),
                       Data("fixture executable".utf8))
    }

    func testMissingResourcesFailsBeforeReplacingAnExistingApp() throws {
        let folder = try makeFixture(includeResources: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("NetMounter.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let marker = app.appendingPathComponent("existing-app")
        try Data("keep".utf8).write(to: marker)
        let result = try runPackaging(in: folder)
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("signed-with-resources").path))
    }

    private func makeFixture(includeResources: Bool) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let build = folder.appendingPathComponent(".build/apple/Products/Release")
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("fixture executable".utf8).write(to: build.appendingPathComponent("NetMounter"))
        if includeResources {
            try FileManager.default.copyItem(at: Bundle.module.bundleURL,
                                            to: build.appendingPathComponent("NetMounter_NetMounter.bundle"))
        }
        let codesign = bin.appendingPathComponent("codesign")
        try Data("""
        #!/bin/bash
        for app in "$@"; do :; done
        test -d "$app/Contents/Resources/NetMounter_NetMounter.bundle" || exit 42
        test -f stripped-debug-paths || exit 44
        touch signed-with-resources
        """.utf8).write(to: codesign)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codesign.path)
        let xcrun = bin.appendingPathComponent("xcrun")
        try Data("""
        #!/bin/bash
        test "$1" = strip && test "$2" = -S || exit 45
        test "$3" = ./NetMounter.app/Contents/MacOS/NetMounter || exit 46
        test -f "$3" || exit 47
        touch stripped-debug-paths
        """.utf8).write(to: xcrun)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
        let swift = bin.appendingPathComponent("swift")
        try Data("#!/bin/bash\nexit 43\n".utf8).write(to: swift)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        return folder
    }

    private func runPackaging(in folder: URL) throws -> (status: Int32, output: String) {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [package.appendingPathComponent("package_app.sh").path]
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = folder.appendingPathComponent("bin").path + ":/usr/bin:/bin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
