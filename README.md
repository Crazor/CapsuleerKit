# CapsuleerKit

A Swift package for EVE Online's official developer services:

- the **SDE over HTTP** at `https://sde.evetech.net` (static data: solar systems, types, …), and
- **ESI**, CCP's REST API at `https://esi.evetech.net`, with EVE SSO login (coming in 0.2).

It is a polite client: caching, conditional requests and a descriptive User-Agent are built in,
not left to the app. Swift 6, async/await, macOS 13 and iOS 16, no dependencies in the library
products.

## Status

**0.1 = SDEKit only. ESIKit and SSO are coming in 0.2.** The API may change between 0.x minor
versions; breaking changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Modules

| Product | What it does |
|---|---|
| `CapsuleerCore` | Shared HTTP pipeline: `HTTPClient`, `URLSessionTransport`, `UserAgent`, memory/disk/tiered cache stores, `LogSink` (`OSLogSink`, `StderrLogSink`), `ClientEvent`, `CapsuleerError`. |
| `SDEKit` | SDE releases and table sync by version hash, offline storage, `SolarSystem` / `SolarSystemTable` with lookup by ID and localised name, `SecurityStatus`. |
| `CapsuleerKitTesting` | `MockTransport` and a controllable clock for your own tests. |
| `capsuleer` | Example and developer CLI (not a library product), e.g. `capsuleer sde system Jita`. |

## Installation

Add the package to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Crazor/CapsuleerKit", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "SDEKit", package: "CapsuleerKit"),
    ]),
]
```

In Xcode: File > Add Package Dependencies…, enter `https://github.com/Crazor/CapsuleerKit`.

## Quick start: SDEKit

```swift
import CapsuleerCore   // UserAgent
import SDEKit

let appSupportURL = URL.applicationSupportDirectory.appending(path: "MyApp/SDE")
let sde = SDEClient(configuration: .init(
    userAgent: UserAgent(product: "MyApp", version: "1.0", contact: "+https://example.com"),
    directory: appSupportURL
))

let systems = try await sde.solarSystems()          // synced on first use, then served from disk
if let security = systems.system(named: "Jita")?.security.displayValue {
    print("Jita: \(security)")                       // "Jita: 0.9"
}
```

The first call downloads the solar-system table (about 1 MB on the wire) and stores it under
the directory you pass. Later calls use the stored copy and re-check the release at most once a
day. If the network is down, the last stored table is used. Use Application Support, not Caches,
so the data stays available offline.

## ESI and SDE etiquette we follow

- **Descriptive User-Agent.** Every request carries your `UserAgent` plus the library's name,
  version and the OS, e.g. `MyApp/1.0 (+https://example.com) CapsuleerKit/0.1.0 macOS/15.0`.
  Put a public way to reach you in `contact`; the library never adds personal data.
- **Caching is ours and visible.** `URLCache` and cookies are off; responses are cached by
  CapsuleerKit according to `Cache-Control` / `Expires`, so apps cannot poll faster than the
  data changes.
- **Conditional requests.** Stale entries are revalidated with `If-None-Match`; a `304` only
  refreshes the entry.
- **Compression.** Requests send `Accept-Encoding: gzip`.
- **Minimal SDE traffic.** The release is checked at most daily, tables are downloaded only when
  their version hash changes, and one sync never mixes two releases.
- **Coalescing.** Identical in-flight requests share one network call.
- **From 0.2 (ESI):** `X-Compatibility-Date` on every request, rate-limit buckets and the error
  budget respected, `Retry-After` honoured, no blind retries of 4XX responses.

## Design

See [DESIGN.md](DESIGN.md) for the architecture, decisions and the roadmap.

## Licence

MIT, see [LICENSE](LICENSE).

## CCP notice

EVE Online and the EVE logo are the registered trademarks of CCP hf. All rights are reserved
worldwide. CapsuleerKit is not affiliated with or endorsed by CCP hf. Use of ESI and SDE data is
subject to the EVE Developer License Agreement.
