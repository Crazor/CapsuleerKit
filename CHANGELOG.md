# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/). During 0.x, minor versions may break the API; each
break is listed here.

## [Unreleased]

### Added
- `SSOConfiguration.isAcceptedCallbackURL(_:)`: the callback URL rules of developers.eveonline.com.

### Fixed
- `WebAuthenticationSession` refuses custom schemes EVE doesn't accept (they must start with
  `eveauth`), and the docs use `eveauth-…://callback` instead of the invalid `overseer://` examples.
- `LoopbackAuthorizationSession` waits until its listener has released the port before
  returning, so a login retried right after a timeout can bind the same port again.

## [0.2.0] - 2026-11-22

### Changed
- Building CapsuleerKit now needs Swift 6.2 (Xcode 26), because ESIKit depends on
  swift-openapi-runtime 1.13 or later.

### Added
- **ESIKit**: client for CCP's ESI at compatibility date 2026-11-19.
  - Endpoints: `character(id).publicInfo()`, `.location()`, `.ship()`, `.online()`;
    `universe.names(_:)`, `universe.ids(_:)`, `universe.structure(_:as:)`.
  - `ESIEtiquetteTransport`: `X-Compatibility-Date`, rate-limit buckets per group and character,
    the shared error budget, `Retry-After`, bounded retries for 5XX and network errors only,
    never retrying other 4XX.
  - Responses cached per identity; names cached 30 days so station names work offline.
  - Endpoint types generated with swift-openapi-generator 1.14.4 from the pinned spec
    (`Scripts/update-esi-spec.sh`), wrapped by hand-written public models.
- **EVE SSO** in ESIKit: `SSOClient` (authorization code + PKCE, refresh, revoke, JWT validation
  with RS256 and ES256), `TokenManager` (single-flight refresh, rotation saved first,
  re-authentication state), `KeychainTokenStore`, `InMemoryTokenStore`,
  `WebAuthenticationSession` (Apple) and `LoopbackAuthorizationSession`.
- SDEKit: `SDEType` and `SDEClient.type(_:)` for ship and item type names.
- CLI: `capsuleer esi login | characters | logout | status | character`.
- Live tests for public ESI and, with `CAPSULEER_LIVE_AUTH=1`, for authenticated calls.
- The weekly upstream watch also reports new ESI compatibility dates and changelog entries for
  the operations in use.
- New `CapsuleerError` codes (`rateLimited`, `errorLimited`, `missingScope`, `notAuthenticated`,
  `reauthenticationRequired`, `ssoFailed`, `inconsistentPages`), `retryAfter`, and new
  `ClientEvent` kinds.

## [0.1.1] - 2026-11-22

### Added
- `SecurityStatus.displayColor` and `SecurityStatus.displayColor(forTenths:)`: the in-game
  colour per displayed tenth, measured from a client after Exordium. Wormhole space and Pochven
  were not measured and use the colour of their displayed value.
- `RGBColor` in CapsuleerCore (8-bit sRGB, `hex`), plus a SwiftUI `Color(_:)` convenience.

### Changed
- The security display rule (values above 0.0 and below 0.05 show as 0.1) is confirmed in game;
  the doc comment and DESIGN.md say so.

## [0.1.0] - 2026-11-22

### Added

- **CapsuleerCore**
  - `HTTPRequest`, `HTTPResponse`, `HTTPHeaders` and the `HTTPTransport` protocol.
  - `URLSessionTransport`: own ephemeral session, `URLCache` and cookies off,
    `Accept-Encoding: gzip`, redirects followed, errors mapped to `CapsuleerError`.
  - `UserAgent`, which appends `CapsuleerKit/<version>` and the OS to the app's product token.
  - `CapsuleerError` with an extensible set of codes.
  - `HTTPClient`: cache lookup, conditional revalidation, 304 handling, stale-if-error and
    coalescing of identical in-flight requests; `Response<T>` with source, expiry and staleness.
  - Cache stores: `MemoryCacheStore`, `DiskCacheStore` and `TieredCacheStore`.
  - Logging through `LogSink`, with `OSLogSink`, `StderrLogSink` and `NullLogSink`; private
    metadata is redacted.
  - `ClientEvent` observability hook and the `TimeSource` clock abstraction.
- **SDEKit**
  - `SDEClient`: release check via `/tranquility/latest/`, release pinning per sync, table sync
    by version hash, offline use of the last stored data.
  - `SDEStore` and `DiskSDEStore`.
  - `SolarSystem`, `SolarSystemTable` (lookup by ID and by any localised name) and
    `SecurityStatus` (display value and security band).
  - Single-record lookup.
- **CapsuleerKitTesting**: `MockTransport` and `ManualTimeSource`.
- `capsuleer` example CLI with `capsuleer sde system <name|id>`.
- CI on macOS for every push and pull request, weekly live
  tests, and a weekly upstream watch of the SDE against `Spec/pins.json`.

[0.2.0]: https://github.com/Crazor/CapsuleerKit/releases/tag/0.2.0
[0.1.1]: https://github.com/Crazor/CapsuleerKit/releases/tag/0.1.1
[0.1.0]: https://github.com/Crazor/CapsuleerKit/releases/tag/0.1.0
