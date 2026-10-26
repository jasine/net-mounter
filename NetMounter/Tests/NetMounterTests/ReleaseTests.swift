import Foundation
import XCTest

/// Exercise the real version/release recipe with a fake artifact and no GitHub or Git writes.
final class ReleaseTests: XCTestCase {
    func testReleaseUpdatesAndStagesBothWebsiteLanguages() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let result = try runRelease(in: fixture, version: "1.4.0")
        XCTAssertEqual(result.status, 0, result.output)
        for path in ["docs/index.html", "docs/script.js", "NetMounter/package_app.sh", "Casks/netmounter.rb"] {
            let content = try String(contentsOf: fixture.appendingPathComponent(path))
            XCTAssertTrue(content.contains("1.4.0"), path)
            XCTAssertFalse(content.contains("1.3.0"), path)
        }
        let calls = try String(contentsOf: fixture.appendingPathComponent("git-calls"))
        XCTAssertTrue(calls.contains("add package_app.sh ../docs/index.html ../docs/script.js ../Casks/netmounter.rb"), calls)
        XCTAssertTrue(calls.contains("push origin main v1.4.0"), calls)
        XCTAssertFalse(calls.contains("--tags"), calls)
    }

    func testReleaseRejectsMalformedVersionBeforeEditingFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let result = try runRelease(in: fixture, version: "1.4")
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(try String(contentsOf: fixture.appendingPathComponent("docs/script.js")).contains("1.3.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("git-calls").path))
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NetMounter Release \(UUID().uuidString)")
        for path in ["NetMounter", "docs", "Casks", "bin"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let recipe = try String(contentsOf: package.appendingPathComponent("Makefile"))
        try (recipe + "\nbuild package:\n\t@true\ndmg:\n\t@printf fixture > NetMounter.dmg\n").write(
            to: root.appendingPathComponent("NetMounter/Makefile"), atomically: true, encoding: .utf8)
        let files = ["NetMounter/package_app.sh": "VERSION=\"${1:-1.3.0}\"\n",
                     "docs/index.html": "v1.3.0 • macOS 14+\n",
                     "docs/script.js": "en: 'v1.3.0 • macOS 14+',\nzh: 'v1.3.0 • macOS 14+'\n",
                     "Casks/netmounter.rb": "version \"1.3.0\"\nsha256 \"old\"\n"]
        for (path, content) in files {
            try content.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let git = """
        #!/bin/sh
        printf '%s\\n' "$*" >> ../git-calls
        case "$1" in
          rev-parse) exit 1 ;;
          symbolic-ref) echo main ;;
          tag) if [ "$2" = --sort=-v:refname ]; then printf 'v1.4.0\\nv1.3.0\\n'; fi ;;
          log) echo '- feat: fixture' ;;
        esac
        exit 0
        """
        for (name, script) in ["git": git, "gh": "#!/bin/sh\nexit 0\n"] {
            let file = root.appendingPathComponent("bin/\(name)")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return root
    }

    private func runRelease(in root: URL, version: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        process.arguments = ["release", "VERSION=\(version)"]
        process.currentDirectoryURL = root.appendingPathComponent("NetMounter")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = root.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin"
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
