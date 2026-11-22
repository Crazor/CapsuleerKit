# CapsuleerKit

A Swift package for EVE Online's official developer services:

- the **SDE over HTTP** at `https://sde.evetech.net` (static data: solar systems, types, …), and
- **ESI**, CCP's REST API at `https://esi.evetech.net`, with EVE SSO login.

It is a polite client: caching, conditional requests and a descriptive User-Agent are built in,
not left to the app. Swift 6, async/await, macOS 13, no dependencies in the library
products.

## Status

**0.2: SDEKit, plus ESIKit with EVE SSO and the character location, ship and online
endpoints.** More ESI endpoints are added as apps need them. The API may change between 0.x minor
versions; breaking changes are listed in [CHANGELOG.md](CHANGELOG.md).

## Modules

| Product | What it does |
|---|---|
| `CapsuleerCore` | Shared HTTP pipeline: `HTTPClient`, `URLSessionTransport`, `UserAgent`, memory/disk/tiered cache stores, `LogSink` (`OSLogSink`, `StderrLogSink`), `ClientEvent`, `CapsuleerError`. |
| `SDEKit` | SDE releases and table sync by version hash, offline storage, `SolarSystem` / `SolarSystemTable` with lookup by ID and localised name, `SecurityStatus` (display value, band, in-game colour), `SDEType`. |
| `ESIKit` | ESI client with built-in etiquette (compatibility date, rate limits, error budget, retries), per-character caching, EVE SSO (PKCE, JWT validation), `TokenManager`, Keychain token store, login sessions for apps and CLIs. |
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

## Quick start: ESIKit and EVE SSO

Register an application at [developers.eveonline.com](https://developers.eveonline.com/) with
the scopes you need and a callback URL your app can receive (a custom URL scheme such as
`myapp://sso-callback`, or `http://127.0.0.1:<port>/callback` for a CLI). Native apps use PKCE
and need no client secret.

```swift
import CapsuleerCore
import ESIKit

let userAgent = UserAgent(product: "MyApp", version: "1.0", contact: "+https://example.com")
let cache = TieredCacheStore(directory: cachesURL.appending(path: "ESI"))
let sso = SSOClient(
    configuration: SSOConfiguration(
        clientID: "<your client ID>",
        callbackURL: URL(string: "myapp://sso-callback")!,
        defaultScopes: [.locationRead, .shipTypeRead, .onlineRead]),
    userAgent: userAgent)
let tokens = TokenManager(sso: sso, store: KeychainTokenStore(service: "com.example.myapp.eve"), cache: cache)
let esi = ESIClient(configuration: ESIConfiguration(userAgent: userAgent, cache: cache, tokenProvider: tokens))

// Log in (macOS: from the main actor, with a window to anchor the sheet).
let session = WebAuthenticationSession(presentationAnchor: { NSApp.keyWindow ?? ASPresentationAnchor() })
let character = try await tokens.authorize(using: session)

// Poll no faster than ESI's cache: schedule the next call for `response.expires`.
let location = try await esi.character(character.id).location()
print(location.value.solarSystemID, location.value.isDocked, location.expires as Any)
```

Ship type names come from SDEKit (`try await sde.type(ship.typeID)`), NPC station names from
`esi.universe.names([stationID])`, and player structure names from
`esi.universe.structure(id, as: characterID)` (needs `esi-universe.read_structures.v1`).

Try it from the command line:

```bash
swift run capsuleer esi login --client-id <id>     # app registered with http://127.0.0.1:8635/callback
swift run capsuleer esi status <character id>
```

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
- **ESI:** `X-Compatibility-Date` on every request, rate-limit buckets per group and character
  and the shared error budget respected, `Retry-After` honoured, 5XX retried with backoff, other
  4XX never retried, scopes checked locally before a request is sent.

## Design

See [DESIGN.md](DESIGN.md) for the architecture, decisions and the roadmap.

## Licence

MIT, see [LICENSE](LICENSE).

## CCP notice

EVE Online and the EVE logo are the registered trademarks of CCP hf. All rights are reserved
worldwide. CapsuleerKit is not affiliated with or endorsed by CCP hf. Use of ESI and SDE data is
subject to the EVE Developer License Agreement.
