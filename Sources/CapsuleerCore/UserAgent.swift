import Foundation

/// The library's version, appended to every User-Agent.
public enum CapsuleerKitInfo {
    public static let version = "0.2.0"
}

/// Identifies the calling app. CapsuleerKit appends its own name, version and the OS.
/// `contact` is chosen by the app (e.g. "+https://example.com/project"); the library never adds personal data.
public struct UserAgent: Sendable, Hashable {
    public var product: String
    public var version: String
    public var contact: String?

    public init(product: String, version: String, contact: String? = nil) {
        self.product = product
        self.version = version
        self.contact = contact
    }

    /// e.g. `Overseer/1.2 (+https://github.com/Crazor/Overseer) CapsuleerKit/0.1.0 macOS/15.0`
    public var headerValue: String {
        var value = "\(product)/\(version)"
        if let contact, !contact.isEmpty { value += " (\(contact))" }
        value += " CapsuleerKit/\(CapsuleerKitInfo.version) \(Self.osToken)"
        return value
    }

    static var osToken: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let name = "macOS"
        #elseif os(iOS)
        let name = "iOS"
        #else
        let name = "OS"
        #endif
        return "\(name)/\(v.majorVersion).\(v.minorVersion)"
    }
}
