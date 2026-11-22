import Foundation

#if canImport(os)
import os

/// Logs through `os.Logger`. Subsystem defaults to "CapsuleerKit"; the category is the log category.
/// `privateMetadata` values are logged with `.private` privacy.
public struct OSLogSink: LogSink {
    public init(subsystem: String = "CapsuleerKit", minimumLevel: LogLevel = .debug) {
        fatalError("TODO(transport agent)")
    }
    public func log(level: LogLevel, category: LogCategory, message: String, metadata: [String: String], privateMetadata: [String: String]) {
        fatalError("TODO(transport agent)")
    }
}
#endif

/// Writes one line per message to stderr (used by the CLI). Private metadata is shown as `<private>`
/// unless `revealPrivate` is true.
public struct StderrLogSink: LogSink {
    public init(minimumLevel: LogLevel = .info, revealPrivate: Bool = false) {
        fatalError("TODO(transport agent)")
    }
    public func log(level: LogLevel, category: LogCategory, message: String, metadata: [String: String], privateMetadata: [String: String]) {
        fatalError("TODO(transport agent)")
    }
}
