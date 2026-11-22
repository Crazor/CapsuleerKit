import Foundation

public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug, info, notice, warning, error
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LogCategory: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let http = LogCategory(rawValue: "http")
    public static let cache = LogCategory(rawValue: "cache")
    public static let ratelimit = LogCategory(rawValue: "ratelimit")
    public static let sso = LogCategory(rawValue: "sso")
    public static let sde = LogCategory(rawValue: "sde")
}

/// Receives log messages. Implementations must never be handed tokens or Authorization headers;
/// callers mark identifying values (character IDs) as private via `privateMetadata`.
public protocol LogSink: Sendable {
    func log(level: LogLevel, category: LogCategory, message: String, metadata: [String: String], privateMetadata: [String: String])
}

extension LogSink {
    public func log(_ level: LogLevel, _ category: LogCategory, _ message: String, metadata: [String: String] = [:], privateMetadata: [String: String] = [:]) {
        log(level: level, category: category, message: message, metadata: metadata, privateMetadata: privateMetadata)
    }
}

/// Discards everything.
public struct NullLogSink: LogSink {
    public init() {}
    public func log(level: LogLevel, category: LogCategory, message: String, metadata: [String: String], privateMetadata: [String: String]) {}
}
