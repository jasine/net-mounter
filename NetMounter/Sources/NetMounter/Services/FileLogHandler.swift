import Foundation
import Logging
import os

struct FileLogHandler: LogHandler {
    private let label: String
    private let writer: LogFileWriter

    var logLevel: Logging.Logger.Level = .debug
    var metadata: Logging.Logger.Metadata = [:]

    init(label: String, writer: LogFileWriter) {
        self.label = label
        self.writer = writer
    }

    func log(event: LogEvent) {
        let ts = Self.formatTimestamp()
        let lvl = event.level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
        let logLine = "[\(ts)] [\(lvl)] [\(label)] \(event.message)\n"
        writer.write(logLine)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    private static func formatTimestamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var tm = tm()
        localtime_r(&tv.tv_sec, &tm)
        var buf = [CChar](repeating: 0, count: 24)
        strftime(&buf, buf.count, "%Y-%m-%d %H:%M:%S", &tm)
        return "\(String(cString: buf)).\(String(format: "%03d", tv.tv_usec / 1000))"
    }
}

// MARK: - LogFileWriter (thread-safe, rotating)

final class LogFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LogFileWriter")
    private let logURL: URL
    private let maxBytes: UInt64
    private let maxFiles: Int
    private var handle: FileHandle?
    private var bytesWritten: UInt64

    init(directory: URL, fileName: String = "netmounter.log", maxBytes: UInt64 = 5_000_000, maxFiles: Int = 3) {
        self.logURL = directory.appendingPathComponent(fileName)
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        self.bytesWritten = (attrs?[.size] as? UInt64) ?? 0
        handle = try? FileHandle(forWritingTo: logURL)
        handle?.seekToEndOfFile()
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        queue.async { [self] in
            handle?.write(data)
            bytesWritten += UInt64(data.count)
            if bytesWritten >= maxBytes {
                rotate()
            }
        }
    }

    private func rotate() {
        handle?.closeFile()
        handle = nil

        let fm = FileManager.default
        let base = logURL.path

        let oldest = "\(base).\(maxFiles)"
        try? fm.removeItem(atPath: oldest)

        for i in stride(from: maxFiles - 1, through: 1, by: -1) {
            let src = "\(base).\(i)"
            let dst = "\(base).\(i + 1)"
            try? fm.moveItem(atPath: src, toPath: dst)
        }

        try? fm.moveItem(atPath: base, toPath: "\(base).1")

        fm.createFile(atPath: base, contents: nil)
        handle = try? FileHandle(forWritingTo: logURL)
        bytesWritten = 0
    }

    deinit {
        handle?.closeFile()
    }
}

// MARK: - Bootstrap helper

enum LogBootstrap {
    static func setup() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NetMounter")
        let writer = LogFileWriter(directory: logDir)

        LoggingSystem.bootstrap { label in
            MultiplexLogHandler([
                FileLogHandler(label: label, writer: writer),
                OSLogHandler(label: label),
            ])
        }
    }
}

// MARK: - OSLogHandler (bridges swift-log → os.Logger)

private struct OSLogHandler: LogHandler {
    private let osLogger: os.Logger
    var logLevel: Logging.Logger.Level = .debug
    var metadata: Logging.Logger.Metadata = [:]

    init(label: String) {
        self.osLogger = os.Logger(subsystem: "com.netmounter.app", category: label)
    }

    func log(event: LogEvent) {
        let msg = "\(event.message)"
        switch event.level {
        case .trace, .debug:
            osLogger.debug("\(msg, privacy: .public)")
        case .info, .notice:
            osLogger.info("\(msg, privacy: .public)")
        case .warning:
            osLogger.warning("\(msg, privacy: .public)")
        case .error, .critical:
            osLogger.error("\(msg, privacy: .public)")
        }
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
}
