# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/). During 0.x, minor versions may break the API; each
break is listed here.

## [0.1.0] - Unreleased

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
- CI on macOS for every push and pull request, an iOS Simulator build on `main`, weekly live
  tests, and a weekly upstream watch of the SDE against `Spec/pins.json`.
