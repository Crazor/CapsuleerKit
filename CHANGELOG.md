# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/). During 0.x, minor versions may break the API; each
break is listed here.

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

[0.1.1]: https://github.com/Crazor/CapsuleerKit/releases/tag/0.1.1
[0.1.0]: https://github.com/Crazor/CapsuleerKit/releases/tag/0.1.0
