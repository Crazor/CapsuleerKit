import CryptoKit
import Foundation
import Testing
import CapsuleerCore
import CapsuleerKitTesting
@testable import ESIKit

@Suite struct JWTValidationTests {
    let time = ManualTimeSource()
    let fetches = SSOLocked<Int>(0)
    let jwksBody = SSOLocked<Data>(SSOTestKeys.jwks([SSOTestKeys.rsaJWK, SSOTestKeys.ecJWK()]))

    func validator() -> JWTValidator {
        let cache = JWKSCache { [fetches, jwksBody] in
            fetches.update { $0 += 1 }
            return try JSONDecoder().decode(JWKSet.self, from: jwksBody.value)
        }
        return JWTValidator(clientID: ssoClientID, jwks: cache, timeSource: time)
    }

    var inTwentyMinutes: Date { time.now().addingTimeInterval(1200) }

    func expectRejected(_ token: String, _ comment: Comment? = nil) async {
        let error = await #expect(throws: CapsuleerError.self, comment) { try await validator().validate(token) }
        #expect(error?.code == .ssoFailed, comment)
    }

    @Test func acceptsRS256AndES256() async throws {
        let validator = validator()
        let rsa = try await validator.validate(makeAccessToken(expiresAt: inTwentyMinutes, signer: .rs256))
        #expect(rsa.character.id == 2112345678)
        #expect(rsa.character.ownerHash == "owner-hash-1")
        let ec = try await validator.validate(makeAccessToken(expiresAt: inTwentyMinutes, signer: .es256()))
        #expect(ec.character.name == "Test Pilot")
        #expect(fetches.value == 1)
    }

    @Test func acceptsBareHostIssuerAndExpiryWithinLeeway() async throws {
        let validator = validator()
        _ = try await validator.validate(makeAccessToken(issuer: "login.eveonline.com", expiresAt: inTwentyMinutes))
        _ = try await validator.validate(makeAccessToken(expiresAt: time.now().addingTimeInterval(-30)))
    }

    @Test func rejectsBadSignature() async {
        await expectRejected(makeAccessToken(expiresAt: inTwentyMinutes, signer: .rs256, tamper: true), "RS256")
        await expectRejected(makeAccessToken(expiresAt: inTwentyMinutes, signer: .es256(), tamper: true), "ES256")
        await expectRejected(makeAccessToken(expiresAt: inTwentyMinutes, signer: .es256(SSOTestKeys.otherECPrivate)), "other EC key")
    }

    @Test func rejectsWrongAudience() async {
        await expectRejected(makeAccessToken(audience: ["someone-else", "EVE Online"], expiresAt: inTwentyMinutes))
        await expectRejected(makeAccessToken(audience: [ssoClientID], expiresAt: inTwentyMinutes))
    }

    @Test func rejectsWrongIssuer() async {
        await expectRejected(makeAccessToken(issuer: "https://login.evil.com", expiresAt: inTwentyMinutes))
    }

    @Test func rejectsExpired() async {
        await expectRejected(makeAccessToken(expiresAt: time.now().addingTimeInterval(-61)))
    }

    @Test func rejectsAlgNoneAndOthers() async {
        await expectRejected(makeAccessToken(expiresAt: inTwentyMinutes, signer: .none))
        await expectRejected(makeAccessToken(expiresAt: inTwentyMinutes, signer: .rs256, alg: "HS256"))
        // An RS256 signature presented as ES256 (algorithm confusion) fails too.
        await expectRejected(makeAccessToken(expiresAt: inTwentyMinutes, signer: .rs256, kid: SSOTestKeys.ecKID, alg: "ES256"))
        await expectRejected("not.a.jwt")
        await expectRejected("onlyonepart")
    }

    @Test func unknownKidRefetchesJWKSOnce() async throws {
        let validator = validator()
        _ = try await validator.validate(makeAccessToken(expiresAt: inTwentyMinutes))
        #expect(fetches.value == 1)

        // Key rotation: the new kid appears in the JWKS after the first fetch.
        let rotated = P256.Signing.PrivateKey()
        jwksBody.set(SSOTestKeys.jwks([SSOTestKeys.rsaJWK, SSOTestKeys.ecJWK(rotated, kid: SSOTestKeys.ecKID)]))
        _ = try await validator.validate(makeAccessToken(expiresAt: inTwentyMinutes, signer: .es256(SSOTestKeys.ecPrivate), kid: SSOTestKeys.ecKID))
        #expect(fetches.value == 1, "known kid: served from cache")

        jwksBody.set(SSOTestKeys.jwks([SSOTestKeys.rsaJWK, SSOTestKeys.ecJWK(rotated, kid: "rotated")]))
        _ = try await validator.validate(makeAccessToken(expiresAt: inTwentyMinutes, signer: .es256(rotated), kid: "rotated"))
        #expect(fetches.value == 2)

        let error = await #expect(throws: CapsuleerError.self) {
            try await validator.validate(makeAccessToken(expiresAt: inTwentyMinutes, kid: "nowhere"))
        }
        #expect(error?.code == .ssoFailed)
        #expect(fetches.value == 3, "exactly one refetch for the unknown kid")
    }

    @Test func rsaKeyFromJWKMatchesSecurityFramework() throws {
        let jwk = try JSONDecoder().decode(JWK.self, from: JSONSerialization.data(withJSONObject: SSOTestKeys.rsaJWK))
        let verifier = try jwk.verifier(for: .rs256)
        let message = Data("hello".utf8)
        let signature = SecKeyCreateSignature(SSOTestKeys.rsaPrivate, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, nil)! as Data
        #expect(verifier.verify(signature: signature, message: message))
        #expect(!verifier.verify(signature: signature, message: Data("hellO".utf8)))
    }
}
