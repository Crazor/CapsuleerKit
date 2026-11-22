import Foundation

#if canImport(os)
import os

/// Logs through `os.Logger`. Subsystem defaults to "CapsuleerKit"; the category is the log category.
/// `privateMetadata` values are logged with `.private` privacy.
///
/// Levels map to `OSLogType` as: debug → `.debug`, info → `.info`, notice → `.default`,
/// warning and error → `.error` (the same mapping as `Logger.warning` / `Logger.error`).
/// Metadata is appended to the message as sorted `key=value` pairs.
public struct OSLogSink: LogSink {
    public let subsystem: String
    public let minimumLevel: LogLevel
    /// One `Logger` per category, shared by all copies of this sink.
    private let loggers: OSAllocatedUnfairLock<[String: Logger]>

    public init(subsystem: String = "CapsuleerKit", minimumLevel: LogLevel = .debug) {
        self.subsystem = subsystem
        self.minimumLevel = minimumLevel
        self.loggers = OSAllocatedUnfairLock(initialState: [:])
    }

    public func log(level: LogLevel, category: LogCategory, message: String, metadata: [String: String], privateMetadata: [String: String]) {
        guard level >= minimumLevel else { return }
        let logger = logger(for: category)
        let type = Self.osLogType(for: level)
        let publicPart = LogFormatting.pairs(metadata)
        let separator = publicPart.isEmpty ? "" : " "
        if privateMetadata.isEmpty {
            logger.log(level: type, "\(message, privacy: .public)\(separator, privacy: .public)\(publicPart, privacy: .public)")
        } else {
            let privatePart = LogFormatting.pairs(privateMetadata)
            logger.log(level: type, "\(message, privacy: .public)\(separator, privacy: .public)\(publicPart, privacy: .public) \(privatePart, privacy: .private)")
        }
    }

    func logger(for category: LogCategory) -> Logger {
        loggers.withLock { cache in
            if let logger = cache[category.rawValue] { return logger }
            let logger = Logger(subsystem: subsystem, category: category.rawValue)
            cache[category.rawValue] = logger
            return logger
        }
    }

    /// Number of categories with a cached `Logger` (for tests).
    var cachedLoggerCount: Int { loggers.withLock { $0.count } }

    static func osLogType(for level: LogLevel) -> OSLogType {
        switch level {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning, .error: .error
        }
    }
}
#endif

/// Writes one line per message to stderr (used by the CLI). Private metadata is shown as `<private>`
/// unless `revealPrivate` is true.
///
/// Line format: `<ISO-8601 time> <level> [<category>] <message> key=value … privateKey=<private>`.
/// Public metadata comes first, then private metadata, each sorted by key. Values with spaces or
/// quotes are quoted; line breaks in the message are escaped so each message stays on one line.
public struct StderrLogSink: LogSink {
    public let minimumLevel: LogLevel
    public let revealPrivate: Bool
    private let timeSource: any TimeSource
    private let write: @Sendable (String) -> Void

    public init(minimumLevel: LogLevel = .info, revealPrivate: Bool = false) {
        self.init(minimumLevel: minimumLevel, revealPrivate: revealPrivate, timeSource: SystemTimeSource()) { line in
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    /// Test seam: `write` receives each complete line, including the trailing newline.
    init(minimumLevel: LogLevel, revealPrivate: Bool, timeSource: any TimeSource, write: @escaping @Sendable (String) -> Void) {
        self.minimumLevel = minimumLevel
        self.revealPrivate = revealPrivate
        self.timeSource = timeSource
        self.write = write
    }

    public func log(level: LogLevel, category: LogCategory, message: String, metadata: [String: String], privateMetadata: [String: String]) {
        guard level >= minimumLevel else { return }
        write(format(level: level, category: category, message: message, metadata: metadata, privateMetadata: privateMetadata) + "\n")
    }

    func format(level: LogLevel, category: LogCategory, message: String, metadata: [String: String], privateMetadata: [String: String]) -> String {
        var line = "\(LogFormatting.timestamp(timeSource.now())) \(LogFormatting.name(of: level)) [\(category.rawValue)] \(LogFormatting.singleLine(message))"
        let publicPart = LogFormatting.pairs(metadata)
        if !publicPart.isEmpty { line += " " + publicPart }
        let privatePart = LogFormatting.pairs(privateMetadata, redacted: !revealPrivate)
        if !privatePart.isEmpty { line += " " + privatePart }
        return line
    }
}

enum LogFormatting {
    static func name(of level: LogLevel) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .warning: "warning"
        case .error: "error"
        }
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// `key=value` pairs sorted by key, separated by spaces. With `redacted`, values become `<private>`.
    static func pairs(_ metadata: [String: String], redacted: Bool = false) -> String {
        metadata.keys.sorted().map { key in
            "\(singleLine(key))=\(redacted ? "<private>" : quoted(metadata[key] ?? ""))"
        }.joined(separator: " ")
    }

    static func quoted(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains { $0.isWhitespace || $0 == "\"" || $0 == "=" }
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(singleLine(escaped))\""
    }

    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
    }
}
