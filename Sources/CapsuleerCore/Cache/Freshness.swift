import Foundation

/// The `Cache-Control` directives the cache acts on.
struct CacheControl: Equatable {
    var noStore = false
    var noCache = false
    var immutable = false
    var maxAge: Int?

    init(_ header: String?) {
        guard let header else { return }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard let rawName = pieces.first else { continue }
            let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
            let value = pieces.count > 1
                ? pieces[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                : nil
            switch name {
            case "no-store": noStore = true
            case "no-cache": noCache = true
            case "immutable": immutable = true
            // An invalid max-age is treated as 0 (stale), per RFC 9111 §4.2.1.
            case "max-age": maxAge = value.flatMap { Int($0) }.map { max(0, $0) } ?? 0
            default: break
            }
        }
    }
}

/// Whether and until when a response may be reused, decided from its headers.
enum Freshness: Equatable {
    /// Must not be written to the cache.
    case doNotStore
    /// Store; fresh until `expires` (nil = revalidate before every use).
    case store(expires: Date?)

    var expires: Date? {
        if case .store(let expires) = self { return expires }
        return nil
    }

    /// Rules, in order: `no-store` → don't store. `no-cache` → store, always revalidate.
    /// `max-age=N` → now + N − Age. `Expires` → now + (Expires − Date) − Age, or the absolute
    /// Expires date without a usable `Date` (unparseable Expires = already stale).
    /// No freshness info → store (always revalidate) only if there is a validator.
    static func evaluate(_ headers: HTTPHeaders, now: Date) -> Freshness {
        let cc = CacheControl(headers["Cache-Control"])
        if cc.noStore { return .doNotStore }
        if cc.noCache { return .store(expires: nil) }
        let age = headers["Age"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { max(0, $0) } ?? 0
        if let maxAge = cc.maxAge {
            return .store(expires: now.addingTimeInterval(TimeInterval(maxAge - age)))
        }
        if let expiresHeader = headers["Expires"] {
            // An invalid date (e.g. "0") means already expired: keep the entry for revalidation.
            guard let expires = HTTPDate.parse(expiresHeader) else { return .store(expires: now) }
            // RFC 9111 §4.2.1: the lifetime is Expires − Date, measured on the server's clock, so a
            // skewed local clock does not stretch or shrink it. Only without a usable Date is the
            // absolute Expires compared with the local clock.
            if let date = headers["Date"].flatMap(HTTPDate.parse) {
                return .store(expires: now.addingTimeInterval(expires.timeIntervalSince(date) - TimeInterval(age)))
            }
            return .store(expires: expires)
        }
        if headers["ETag"] != nil || headers["Last-Modified"] != nil { return .store(expires: nil) }
        return .doNotStore
    }
}
