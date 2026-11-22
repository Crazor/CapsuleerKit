import CapsuleerCore
import CryptoKit
import Foundation
import Security

/// RFC 7636 PKCE values and the base64url helpers shared by the SSO code.
enum PKCE {
    /// 32 random bytes, base64url without padding: 43 characters from `[A-Za-z0-9-_]`.
    static func makeCodeVerifier() throws -> String {
        try Base64URL.encode(randomBytes(count: 32))
    }

    /// `BASE64URL(SHA256(ASCII(code_verifier)))` (method `S256`).
    static func codeChallenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A random, unguessable `state` value (16 bytes, base64url).
    static func makeState() throws -> String {
        try Base64URL.encode(randomBytes(count: 16))
    }

    static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw CapsuleerError(.ssoFailed, message: "Could not generate random bytes (OSStatus \(status))")
        }
        return Data(bytes)
    }
}

/// base64url (RFC 4648 §5) without padding.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url with or without padding; nil for invalid input.
    static func decode(_ string: String) -> Data? {
        guard string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "=") }) else { return nil }
        var base64 = string
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch base64.count % 4 {
        case 0: break
        case 2: base64 += "=="
        case 3: base64 += "="
        default: return nil
        }
        return Data(base64Encoded: base64)
    }
}

/// `application/x-www-form-urlencoded` encoding with a strict unreserved set, used for both the
/// authorize URL's query and the token endpoint's form bodies.
enum FormEncoding {
    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }
}
