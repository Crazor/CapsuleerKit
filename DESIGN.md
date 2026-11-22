# CapsuleerKit design

Status: draft for review, 2026-11-22. Nothing here is implemented yet.

CapsuleerKit is a Swift package for EVE Online's official developer services:

- **ESI**, CCP's REST API at `https://esi.evetech.net`, with EVE SSO login (OAuth 2.0, SSO v2).
- **SDE over HTTP**, CCP's static data service at `https://sde.evetech.net`.

It lives in its own public, MIT-licensed repo, `github.com/Crazor/CapsuleerKit`. Overseer is
its first consumer, but the package knows nothing about Overseer or Overseer's dependencies
(`Defaults`, `KeyboardShortcuts`, `Sparkle`).

Versioning: 0.x until the API settles. Each 0.x release contains only what Overseer needs at
that point:

- **0.1:** CapsuleerCore + SDEKit. There is no ESIKit code yet.
- **0.2:** the ESIKit pipeline, SSO and the phase-2 character endpoints.

The ESI design is written down now, so 0.2 can be added without breaking 0.1's API.

## 1. Background and findings

These facts drive the design. All were checked live on 2026-11-22.

- **ESI dropped static data.** From compatibility date **2026-11-19**, ESI no longer serves the
  static `/universe/*` routes, including `GET /universe/systems/{system_id}`. Requests return 404.
  The `/universe` routes that remain are `ids`, `names`, `structures`, `system_jumps` and
  `system_kills`. Older compatibility dates (for example 2026-08-18) still serve the removed
  routes, but CCP has published no end date for them, so CapsuleerKit does not rely on them.
- **Static data now comes from the SDE.**
  - `https://sde.evetech.net/tranquility/latest/` returns a 302 redirect to a fixed release, for
    example `/tranquility/20261120T165826Z/`. That URL serves a manifest with a version hash per
    table and the table's URLs.
  - Only the current and the previous release are kept.
  - A single record lives at `/tranquility/<release>/<table>/<key>.json`. It is served with
    `Cache-Control: public, max-age=31536000, immutable` and a strong ETag.
  - A whole table is available as `/tranquility/<release>/<table>.jsonl`. It is always gzipped.
    `mapSolarSystems.jsonl` holds 8,490 systems: 4.8 MB raw, 1.1 MB on the wire.
  - The SDE has no auth, no rate-limit headers and no name lookup.
- **The ESI OpenAPI spec is published per compatibility date.**
  - URL: `https://esi.evetech.net/meta/openapi.json?compatibility_date=YYYY-MM-DD`. Without the
    parameter you get 2020-01-01.
  - The valid dates are listed at `/meta/compatibility-dates`. Changes per date are at
    `/meta/changelog`, typed as `removed` and so on.
  - Each operation in the spec carries:
    - `x-compatibility-date`
    - `x-rate-limit {group, max-tokens, window-size}` (135 of 197 operations at 2020-01-01)
    - `x-cache-age` / `x-client-cache-ttl`
    - its OAuth scopes under `security`
- **`swift-openapi-generator` 1.x handles the 2026-11-19 spec.** With the spec filtered to
  `PostUniverseIds`, `PostUniverseNames`, `GetCharactersCharacterIdLocation`, `…Ship`,
  `…Online`, `GetCharactersDetail` and `GetCharactersCharacterIdPortrait`, it builds cleanly and
  produces about 3,900 lines. `X-Compatibility-Date` becomes a required enum header parameter
  whose only case is the snapshot's date.
- **ESI response headers seen live:**
  - caching: `ETag`, `Expires`, `Last-Modified`, `Cache-Control`
  - rate limits: `X-Ratelimit-Group`, `X-Ratelimit-Limit` (`150/15m`), `X-Ratelimit-Remaining`,
    `X-Ratelimit-Used`
  - error limit: `X-Esi-Error-Limit-Remain`, `X-Esi-Error-Limit-Reset`
  - other: `Vary: Accept-Language, X-Compatibility-Date, X-Tenant`
  - Responses to `POST /universe/ids` carry no cache headers, although the docs say names are
    cached for 12 hours.

## 2. Goals and non-goals

**Goals**

- A correct, polite client: ESI etiquette is built in, not left to the app.
- A typed, async/await API that stays stable across ESI spec updates.
- Offline-first static data: each piece is looked up once, then served from disk.
- SSO for native apps with several characters and safe token handling (built in 0.2, designed
  now so 0.2 needs no breaking changes).
- macOS. iOS and Linux are deferred, but the code keeps the seams that make it cheap to add (§3).

**Non-goals**

- Anything outside the official ESI, SSO and SDE services: no game input, no game memory, no
  screen analysis, no unofficial mirrors.
- Covering every ESI endpoint. Operations are added when an app needs them.
- Linux in 0.1. It is reconsidered in 0.2, when the isolation for authenticated live tests is
  chosen (§7).
- A server-side, multi-user token vault.
- Windows.

## 3. Repo layout and packaging

```
CapsuleerKit/                     ← repo root = package root (github.com/Crazor/CapsuleerKit, public)
  Package.swift                   swift-tools-version 6.0, Swift 6 language mode
  LICENSE                         MIT
  README.md                       includes CCP's third-party notice
  DESIGN.md                       this document
  CHANGELOG.md
  Sources/
    CapsuleerCore/                shared: HTTP pipeline, cache stores, User-Agent, logging, events
    SDEKit/                       SDE release and table sync, record lookup, models (depends on Core only)
    ESIKit/                       ESI client, etiquette, endpoints, models; SSO and tokens from 0.2
      Generated/                  swift-openapi-generator output, committed (internal access)
    CapsuleerKitTesting/          MockTransport, fixture loader, in-memory stores (separate product)
    capsuleer/                    example and dev CLI (executable target, not a library product)
  Tests/
    CapsuleerCoreTests/  SDEKitTests/  ESIKitTests/
    LiveTests/                    hit real ESI, SDE and SSO; skipped unless CAPSULEER_LIVE=1
    Fixtures/                     recorded request/response pairs (JSON)
  Spec/
    esi-openapi-<date>.json       pinned, unfiltered spec snapshot
    openapi-generator-config.yaml operation filter, accessModifier: internal, namingStrategy: idiomatic
    pins.json                     pinned ESI compatibility date and SDE release / table versions
  Tools/                          separate nested package holding swift-openapi-generator,
                                  so consumers never resolve the generator
  Scripts/
    update-esi-spec.sh <date>     fetch the snapshot, regenerate into Sources/ESIKit/Generated
    record-fixtures.sh            record fixtures from live ESI and SDE
    check-upstream.sh             compare pins.json with live ESI/SDE metadata (used by the weekly job)
  .github/workflows/              see §7
```

**Products:** `CapsuleerCore`, `SDEKit`, `ESIKit` and `CapsuleerKitTesting`. An app imports only
what it uses.

**Dependencies:**

| Module | Dependencies |
|---|---|
| `CapsuleerCore` | none |
| `SDEKit` | none |
| `ESIKit` | `apple/swift-openapi-runtime` (≥ 1.13) and `apple/swift-http-types` (Apache-2.0, both from Apple). No `swift-openapi-urlsession`: `PipelineClientTransport` sends through the CapsuleerCore pipeline. The generator (1.14.4, pinned exactly) lives in the separate `Tools/` package. |
| `capsuleer` CLI | `apple/swift-argument-parser` |

In 0.1 the only dependency is `swift-argument-parser`, and only for the CLI. The library
products have none.

**Platforms:** macOS 13, matching Overseer's deployment target. iOS is deferred until an app
needs it; the code uses no AppKit, so adding `.iOS(.v16)` and an iOS CI job is all it takes.

**Linux is deferred,** but the code stays easy to port:

- Foundation-only. No AppKit or UIKit in the library.
- Every Apple-only API sits behind a protocol and `#if canImport(...)`:

  | Concern | Seam | Apple implementation | Possible Linux implementation |
  |---|---|---|---|
  | Logging | `LogSink` | `OSLogSink` | `StderrLogSink` |
  | Token storage | `TokenStore` | `KeychainTokenStore` | in-memory or file store |
  | JWT signature check | internal `SignatureVerifier` | Security.framework | swift-crypto |
  | Login UI | `AuthorizationSession` | `WebAuthenticationSession` | loopback listener |

- Adding Linux later means `import FoundationNetworking`, the Linux implementations above, and a
  Linux CI job.

**Language:** Swift 6 language mode with strict concurrency, chosen for compile-time data-race
checking in the cache, the rate limiter and token refresh. No other Swift 6 feature is required.
Building the package needs Xcode 26 (Swift 6.2), because swift-openapi-runtime 1.13+ requires
it; Overseer can stay in Swift 5 language mode.

**Licence:** MIT, matching Overseer. The README carries CCP's notice: EVE Online and the EVE
logo are registered trademarks of CCP hf., and the project is not affiliated with or endorsed by
CCP. Use of ESI and SDE data falls under CCP's developer licence.

**How Overseer depends on it:**

- A remote package reference (`https://github.com/Crazor/CapsuleerKit`), pinned to a tag. During
  0.x a branch or commit is fine.
- To work on both at once, add the local checkout to the Overseer Xcode project. A local package
  with the same name overrides the remote one, and the override is removed before committing.

**Versioning:** SemVer. 0.x minor versions may break the API; each break is noted in
`CHANGELOG.md`.

## 4. CapsuleerCore: the HTTP pipeline

Each request runs through these stages in order. ESI adds its own stages; the SDE uses the core
stages only.

1. **Build the request.** Set the User-Agent and, for ESI, `X-Compatibility-Date`,
   `Accept-Language` and `Authorization`.
2. **Cache lookup** (`HTTPCache`). Return a fresh entry without touching the network, or attach
   `If-None-Match` to revalidate a stale one.
3. **Admission** (ESI only). The rate-limit bucket and the error budget may delay the request or
   refuse it.
4. **Transport** (`HTTPTransport`). The default is `URLSessionTransport`.
5. **Response handling.** Update the limiter state; on a 304, refresh the cached entry's expiry;
   store cacheable 200s; map errors; retry where the policy allows it.

### Transport

```swift
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse   // body: Data
}
```

- `URLSessionTransport` runs on its own ephemeral `URLSession` with `urlCache = nil` and
  `.reloadIgnoringLocalCacheData`, so all caching is ours and visible.
- `URLSessionTransport` sends `Accept-Encoding: gzip`. URLSession decompresses responses on its
  own.
- Tests inject `MockTransport`, which replays fixtures or runs closures.

### User-Agent

- The app provides it through `UserAgent(product: "Overseer", version: "1.2", contact: …)`.
- The library appends `CapsuleerKit/<version>` and the OS, for example:
  `Overseer/1.2 (+https://github.com/Crazor/Overseer) CapsuleerKit/0.1 macOS/15.0`.
- `contact` is optional and chosen by the app, for example a project URL. The library never adds
  personal data. CCP asks for a way to contact the developer, so a public project URL is the
  intended use.

### HTTP cache

- **Cache key:** method + URL + body hash (POST) + identity (`public` or the character ID) +
  compatibility date + `Accept-Language`. This mirrors ESI's `Vary` headers and keeps one
  character's data from ever being served to another.
- **Store protocol** (pluggable, so the app chooses where data lives):

  ```swift
  public protocol CacheStore: Sendable {
      func entry(for key: CacheKey) async -> CacheEntry?
      func store(_ entry: CacheEntry, for key: CacheKey) async
      func remove(_ key: CacheKey) async
      func removeAll(identity: CacheIdentity?) async     // e.g. on logout
  }
  ```

  - `CacheEntry` holds: body, status, ETag, Last-Modified, Expires, stored-at time and the
    response headers that matter.
  - Built-in stores:
    - `MemoryCacheStore`: LRU, bounded by bytes.
    - `DiskCacheStore(directory:)`: one file per entry (metadata header + body), atomic writes,
      size cap with LRU eviction.
    - `TieredCacheStore(memory, disk)`: the default.
  - The app passes the directory. Overseer would use
    `~/Library/Caches/<bundle id>/CapsuleerKit/`.
- **Freshness:**
  - An entry is fresh until `now + max-age − Age` (`Cache-Control: max-age`, `immutable`), otherwise
    until `Expires`. `no-cache` stores the entry but always revalidates. A response without
    freshness information is stored only if it has an `ETag` or `Last-Modified`.
  - `no-store` responses are never written.
  - Authenticated responses go only to stores the app has marked as allowed to hold private data.
    The default disk store allows it, since it lives in the user's own container.
- **Cache policy per call:**

  | Policy | Behaviour |
  |---|---|
  | `.useProtocolCachePolicy` | Default. Fresh: serve from cache. Stale: revalidate. |
  | `.returnCacheDataElseLoad` | Any cached entry, even stale. Offline-first. |
  | `.reloadRevalidatingCacheData` | Always ask the server, with `If-None-Match`. |

  With every policy, if the network fails and a stale entry exists, the stale entry is returned
  with `isStale = true` (stale-if-error) instead of throwing.
- **Result:** every call returns
  `Response<T> { value, source (.network/.cache/.revalidated), expires, lastModified, isStale }`,
  so apps can schedule their next poll for `expires` instead of guessing.
- **POSTs:** ESI POST responses carry no cache headers, so the HTTP cache does not store them.
  Higher-level helpers that know the data is stable (name → ID) keep their own small cache in the
  same `CacheStore`, with an explicit TTL.

### Logging and events

- Logging goes through a small `LogSink` protocol (level, category, message, metadata), so there
  is no `swift-log` dependency.
  - Built-in sinks: `OSLogSink` (Apple; the subsystem is configurable and defaults to
    `CapsuleerKit`), `StderrLogSink` (the CLI) and `NullLogSink`.
  - Categories: `http`, `cache`, `ratelimit`, `sso` and `sde`.
  - Tokens and `Authorization` headers are never logged. Character IDs are marked private.
- An optional `events: @Sendable (ClientEvent) -> Void` hook reports metrics such as request
  finished, cache hit, rate-limit wait, error budget low, token refreshed and reauthentication
  needed. Overseer can show these in a debug view.

## 5. ESIKit

### 5.1 Endpoint layer: generated, committed, wrapped

- `Scripts/update-esi-spec.sh <date>`:
  1. Downloads `openapi.json?compatibility_date=<date>` into `Spec/`.
  2. Runs the generator from `Tools/` with the operation filter in
     `Spec/openapi-generator-config.yaml`.
  3. Writes the output to `Sources/ESIKit/Generated/`.
  4. Updates `ESI.compatibilityDate`.
- The generated code is **internal**. The public API is a hand-written facade with hand-written
  public models, for example `CharacterLocation`, `CharacterShip`, `CharacterOnline` and
  `ResolvedIDs`. Each model maps from the generated type. Spec churn (renamed fields, new
  optional fields) then stays inside the module and does not break apps.
- **Why commit the output instead of using the build plugin:** builds are faster, Xcode shows no
  plugin trust prompt, consumers don't resolve the generator, and each spec update is a reviewed
  diff.
- **Updating the compatibility date is a deliberate change.** Read `/meta/changelog` for the used
  operations, regenerate, fix the mappings, run the fixture tests, and note it in the changelog.
  The date lives in one constant. A test checks that the constant matches the generated enum
  case.
- **Wiring the generated client into the pipeline:** the generated `Client` takes an
  OpenAPIRuntime `ClientTransport`. ESIKit supplies `PipelineClientTransport`, which forwards to
  the CapsuleerCore pipeline, so the OpenAPI runtime never sees caching or rate limits. Spec
  extensions the generator drops (`x-rate-limit`, `security` scopes, `x-client-cache-ttl`) go
  into a small generated table, `OperationMetadata[operationID]`, written by the update script.
- **Endpoint growth:** a new endpoint means adding its operation ID to the filter, regenerating,
  and writing a facade method and model.

### 5.2 Etiquette (all automatic)

| Rule | Implementation |
|---|---|
| Descriptive User-Agent | From `UserAgent` config, see §4. Required at `ESIClient` init, so there is no default. |
| `X-Compatibility-Date` | Pinned constant from the spec snapshot; on every request. |
| ETag / `If-None-Match` | Sent from the cached entry; a 304 refreshes the entry's expiry. |
| Respect `Expires` | A fresh cache entry answers without a network call, so apps can't poll faster than the cache. |
| Rate-limit buckets | `RateLimiter` actor, keyed by `(group, identity)`: the client ID plus character for authenticated calls, `public` otherwise. Seeded from `x-rate-limit` (max tokens, window) and corrected from each response's `X-Ratelimit-Remaining` / `-Used`. ESI's token cost is 2XX = 2, 3XX = 1, 4XX = 5, 5XX = 0. When remaining tokens fall below a reserve (default 10 %), requests are spaced out over the window instead of bursting. Operations without a group are limited only by the error budget. |
| Error-limit budget | `ErrorBudget` actor shared by all calls. It tracks `X-Esi-Error-Limit-Remain` and `-Reset`. At or below a floor (default 10), every request waits until the reset. A 420 response sets the budget to 0 until the reset. |
| `Retry-After` | On 429 or 503: wait the given time, then retry at most once. If the wait is longer than the caller's deadline, throw `.rateLimited(retryAfter:)` instead. |
| No blind 4XX retries | 400/401/403/404/422 and every other 4XX are never retried. A 401 on an authenticated call invalidates the access token, gets a new one and retries exactly once. If the fresh token is rejected too, the 401 is thrown and further 401s for that character are thrown without refresh or retry for `unauthorizedCooldown` (default 5 min), so a locked account can't drain the shared error budget. A successful call ends the cooldown. |
| 5XX and network errors | At most 2 retries with exponential backoff and jitter (1 s, 3 s), only for idempotent GETs and for the POSTs ESI documents as lookups (`/universe/ids`, `/universe/names`). |
| Pagination (`X-Pages`) | `pages(...)` fetches page 1, then pages 2…N with bounded concurrency (default 3). All pages must report the same `Last-Modified`. If they don't, the data changed mid-read, and the whole set is refetched, up to 2 times, before throwing `.inconsistentPages`. It returns `Response<[T]>`. Built in 0.2, or when the first paged endpoint arrives. |
| Concurrent duplicates | Identical in-flight requests (same cache key) are coalesced into one network call. |

### 5.3 First public endpoint (0.2)

ESIKit starts in 0.2. Its first public endpoint is chosen to exercise the whole pipeline: a GET
with ETag, Expires and rate-limit headers.

```swift
let esi = ESIClient(configuration: .init(
    userAgent: UserAgent(product: "Overseer", version: "1.2", contact: "+https://github.com/Crazor/CapsuleerKit"),
    cache: TieredCacheStore(directory: cachesURL)))

let info = try await esi.characters.publicInfo(2112345678)   // GET /characters/{id}: name, corp, alliance, …
```

Planned next, when an app needs them:

- `POST /universe/names` (0.2): batches of at most 1000 IDs (the spec's `maxItems`); resolved
  names are cached per ID for 30 days, in process and in the cache store, so station names work
  offline. A batch with one invalid ID returns 404 for the whole batch; it is not split.
- `POST /universe/ids` (0.2): batches of at most 500 names; only exact (case-insensitive) name
  matches are returned, since ESI also matches tickers. Resolved names are cached 12 hours,
  unresolved ones 1 hour.
- `EVEImages.characterPortrait(id, size:)`, a URL helper for CCP's image server
  (`https://images.evetech.net/characters/{id}/portrait?size=…`). The app loads and caches the
  image itself.

### 5.4 SSO and authenticated calls (0.2; designed now)

**App-provided configuration.** The library hard-codes no app identity.

```swift
let sso = SSOConfiguration(
    clientID: "…",                                     // from developers.eveonline.com
    callbackURL: URL(string: "eveauth-overseer://callback")!,
    defaultScopes: [.locationRead, .shipTypeRead, .onlineRead])
```

- Overseer registers the URL scheme in its `Info.plist` and the callback URL in its CCP
  application.
- The library checks that the redirect it receives matches `callbackURL` exactly.
- The callback can be any URL the app can receive: a custom scheme (Overseer) or a loopback
  `http://127.0.0.1:<port>/callback` (the CLI).

**Platform split:**

- `SSOClient` is platform-neutral. It builds the authorize URL and PKCE values, exchanges the
  code, refreshes and revokes tokens, and validates the JWT.
- Getting the redirect back to the app is a separate `AuthorizationSession` protocol:
  - `WebAuthenticationSession` (Apple, wraps `ASWebAuthenticationSession`)
  - `LoopbackAuthorizationSession` (CLI; a one-shot local HTTP listener)

**Login flow:** OAuth 2.0 authorization code with PKCE (no client secret).

1. Build a 32-byte random `code_verifier`, its `S256` `code_challenge`, and a random `state`.
2. Open `https://login.eveonline.com/v2/oauth/authorize?response_type=code&client_id=…&redirect_uri=…&scope=…&state=…&code_challenge=…&code_challenge_method=S256`
   through the `AuthorizationSession`. On Apple it uses
   `prefersEphemeralWebBrowserSession = true`, so each login can pick a different character.
3. Check that `state` matches, then POST to `https://login.eveonline.com/v2/oauth/token`
   (form: `grant_type=authorization_code`, `code`, `client_id`, `code_verifier`).
4. Validate the JWT access token, then store the character.

- The presentation anchor is passed in by the app. `ASWebAuthenticationSession` needs one on
  macOS.
- Endpoints are read from `https://login.eveonline.com/.well-known/oauth-authorization-server`
  and cached, with the documented URLs as fallback.

**JWT validation** uses Security.framework for RS256 signatures (`SecKeyVerifySignature`), behind
an internal `SignatureVerifier`. There is no JWT dependency. The checks:

- The signature must verify against the JWKS, found through the metadata's `jwks_uri`. The JWKS
  is cached and refetched once when a `kid` is unknown.
- `iss` must be `https://login.eveonline.com` (or the bare host).
- `aud` must contain both the client ID and `"EVE Online"`.
- `exp` must be in the future, with 60 s leeway.
- From the claims, the client reads:
  - `sub = "CHARACTER:EVE:<id>"`, giving the character ID
  - `name`
  - `owner`, the owner hash
  - `scp`, the granted scopes (a string or an array)

**Characters and scopes:**

- Every character is an independent `AuthorizedCharacter`, holding the ID, name, owner hash,
  granted scopes and state (`.active` or `.needsReauthentication(reason)`).
- Each character can be authorized with its own scopes. EVE grants exactly the scopes in the
  authorize URL, and which character logs in is only known afterwards, so
  `authorize(scopes:mergingWith:)` adds a known character's stored scopes to the request. The
  stored scopes are always the new token's `scp` claim. The replaced refresh token is *not*
  revoked: EVE's revocation ends the whole grant for the character and application, so it would
  also kill the new login (verified live 2026-11-22). Only `logout` revokes.
- A character that needs re-authentication stays stored with an empty refresh token and state
  `.needsReauthentication(reason)`, so apps can list it and offer a new login.
- Before sending, an endpoint call checks the operation's required scopes (from
  `OperationMetadata`) against the character's granted scopes. A missing scope throws
  `.missingScope(…)` without making a network request.

**Tokens:**

- `TokenStore` protocol, with these implementations:
  - `KeychainTokenStore(service:accessGroup:)`: a generic password item per character, holding
    the refresh token, owner hash and scopes.
  - `InMemoryTokenStore` (public, in ESIKit), for tests.
  - `FileTokenStore(url:)`, in the CLI target only (not a library product). It is a JSON file
    with mode 0600, used by the live test runner.
- Access tokens (about 20 minutes) are kept in memory only.
- `TokenManager` is an actor:
  - It refreshes 60 s before `exp`.
  - Refresh is single-flight per character: one stored `Task` that concurrent callers await, so
    a refresh token is never used twice in a race.
  - Every refresh response replaces the stored refresh token, since EVE may rotate it. The new
    token is written to the `TokenStore` before the new access token is used, so a crash can't
    lose the only valid refresh token.
- **When refresh fails:**
  - `invalid_grant` or a 400 from the token endpoint: the token was revoked, the user changed
    their password, or the character was transferred. The character becomes
    `.needsReauthentication`, its refresh token is deleted, `ClientEvent.reauthenticationRequired`
    is sent, and calls throw `.reauthenticationRequired(characterID)`. There is no retry.
  - Network errors or 5XX: back off; the stored token stays valid.
  - An `owner` hash that differs from the stored one: the character has a new owner. Treat it
    like `invalid_grant` and clear that character's cached private data.
- **Logout:** POST to `https://login.eveonline.com/v2/oauth/revoke` with the refresh token
  (best effort), delete the Keychain item, and call `cache.removeAll(identity:)`.

**Authenticated endpoints for Overseer phase 2:**

```swift
let me = esi.character(2112345678)                   // requires an authorized character
let loc    = try await me.location()   // solar_system_id, station_id?, structure_id?  → docked = either present
let ship   = try await me.ship()       // ship_type_id, ship_item_id, ship_name
let online = try await me.online()     // online, last_login, last_logout
```

- `location` and `ship` have a 5 s client cache TTL and belong to the `char-location` group
  (1,200 tokens per 15 minutes). Apps poll on `Response.expires`, never faster.
- Ship type names come from SDEKit's `types` table, since ESI no longer serves `/universe/types`.
- NPC station names come from the SDE's `npcStations` table. Player structure names come from
  `GET /universe/structures/{id}`, which needs `esi-universe.read_structures.v1`.

### 5.5 Public API shape

- Everything is async/await.
- `ESIClient` and `SDEClient` are `final class … : Sendable` with immutable configuration.
  Mutable state lives in internal actors (`RateLimiter`, `ErrorBudget`, `TokenManager`,
  `RequestCoalescer`), so callers never hop onto a library actor and the API works from any
  isolation, including `@MainActor` UI code.
- All public models are `Sendable`, `Hashable` and `Codable` value types. IDs are typed
  (`SolarSystemID`, `CharacterID`, `TypeID`, …) as `RawRepresentable` `Int64` wrappers.
- **Errors:** a single `CapsuleerError: Error, Sendable` struct, holding `code` (an extensible
  struct of static values such as `.notFound`, `.rateLimited`, `.errorLimited`,
  `.missingScope`, `.reauthenticationRequired`, `.inconsistentPages`, `.decoding`,
  `.transport`, `.sdeReleaseUnavailable`), the HTTP status, ESI's `error` message, `retryAfter`
  and the underlying error. A struct instead of an enum means new codes don't break apps'
  exhaustive switches.
- Cancellation is honoured everywhere, including while waiting on the rate limiter.
- **Testability:**
  - `CapsuleerKitTesting` provides `MockTransport` (fixture replay plus request assertions),
    `MemoryCacheStore` and a controllable `ManualTimeSource`
    injected into the cache, the limiter and the token manager.
  - Fixtures are recorded from live public endpoints by `Scripts/record-fixtures.sh`. SSO
    fixtures are hand-written with a test JWKS key pair.

## 6. SDEKit

### 6.1 Releases and tables

```swift
let sde = SDEClient(configuration: .init(userAgent: ua, store: DiskSDEStore(directory: appSupportURL)))
let release = try await sde.currentRelease()          // manifest: release id, build number, table versions
let systems = try await sde.solarSystems()            // SolarSystemTable, synced on first use
```

- **Release check:** `GET /tranquility/latest/` follows the 302 to the release manifest. The
  manifest is cached for its `max-age` (300 s for the redirect, 86400 s for the manifest), and
  is checked at most once per launch and at most daily (configurable).
- **Table sync:** downloads `<table>.jsonl` for the pinned release. The table's `version` hash is
  stored, and a table is downloaded again only when its hash changes. Tables can be unchanged
  across releases, and the `_changes` table can enable incremental updates later.
- **Pin the release.** All downloads in one sync use the same release URL, never `latest`, so
  one sync can't mix two releases.
- **Persistence:** `SDEStore` protocol, which keeps the decoded table with its release and version
  hash (not the raw JSONL). Table downloads bypass the HTTP cache.
  `DiskSDEStore` writes it to the app-chosen directory, which should be Application Support,
  not Caches, so it stays available offline. A sync replaces data atomically.
- **Offline:** if the release check or a download fails, the last stored table is used and
  `isStale` is reported. Only a first launch with no network fails, with
  `.sdeReleaseUnavailable`.
- **Single records:** `sde.record(SomeModel.self, table: "types", key: 587)` for apps that need
  a few records, not whole tables. These are immutable per release, so they live in the HTTP
  cache with no expiry until the release changes.

### 6.2 Models (0.1)

- `SolarSystem` holds: `id`, `name: LocalizedString` (`en` required; `de`, `fr`, `ja`, `ko`,
  `ru`, `zh`, `es`), `securityStatus: Double`, `securityClass: String?`, `regionID`,
  `constellationID`, `factionID?` and `wormholeClassID?`.
- `SolarSystemTable` offers:
  - `system(id:)`
  - `system(named:)`, which ignores case and matches every localised name, since the chat log
    may use the client's language (7 systems have a German name that differs from the English
    one)
  - `all`
- `SecurityStatus` display helper: `displayValue` (one decimal) and `band` (`.high` at ≥ 0.45,
  `.low` above 0.0, `.null` at ≤ 0.0, `.wormhole` / `.pochven` by region). Values in (0, 0.05)
  display as 0.1, confirmed in game on 2026-11-22 (Egbinger 0.0346 and Ennur 0.0583 show 0.1).
- `SecurityStatus.displayColor` (0.1.1): the in-game colour per displayed tenth as an `RGBColor`,
  measured from a client after Exordium (1.0 has its own colour). Not part of the SDE. Wormhole
  space and Pochven were not measured and use the colour of their displayed value.
- Later, when an app needs them: `Type` (from `types`, for ship names), `NPCStation`, `Region` and
  `Constellation`, added when an app needs them.

## 7. Testing and CI

### Test layers

| Layer | Where | Runs |
|---|---|---|
| Unit tests (`MockTransport`, controllable clock, fixtures, test JWKS key pair) | `Tests/*Tests` | Every push and PR, GitHub-hosted macOS runner (free for public repos) |
| Live public tests (SDE manifest and record, `GET /characters/{id}`, header and etiquette assertions) | `Tests/LiveTests` | Nightly or weekly, plus manual runs |
| Live authenticated tests (refresh, `location`, `ship`, `online`, scope checks, revoke handling) | `Tests/LiveTests` | Nightly or weekly, plus manual runs, **self-hosted runner only** |

### Live authenticated tests on a self-hosted runner

- **CCP application:** a separate "CapsuleerKit CI" application on developers.eveonline.com,
  with a loopback callback and only the scopes under test. It is not Overseer's application.
- **Character:** a dedicated alt with nothing of value, logged in once by hand with
  `capsuleer login --store <path>`.
- **Refresh token:** it never goes into GitHub secrets. It lives in a `FileTokenStore` on the
  runner host, mounted into the job's VM or container. EVE may hand out a new refresh token on every
  refresh; `TokenManager` writes it back to that file, so rotation needs no write-back to GitHub.
- **Runner, decided in 0.2:** an ephemeral, isolated runner on the user's Mac, so a job can
  reach only the token file and the network. Two options:
  - **Tart macOS VM:** a fresh VM per job, no Linux support needed. Apple's licence allows at
    most 2 macOS VMs per Mac.
  - **Linux container** (Docker Desktop, OrbStack or Colima, official `actions/runner` image with
    `--ephemeral`): lighter, but requires adding Linux support first.

  A native macOS runner (a launchd service) is ruled out. It runs as the user and can reach
  their files and Keychain.
- **Public-repo safety.** A self-hosted runner on a public repo would run code from anyone's
  pull request unless the workflows prevent it:
  - Self-hosted jobs trigger only on `schedule`, `workflow_dispatch` and `push` to `main`.
    Never on `pull_request` or `pull_request_target`.
  - The runner sits in its own runner group, restricted to this repo and to that one workflow
    file.
  - Repo setting: require approval for workflow runs from all outside contributors.
  - The workflow has read-only `GITHUB_TOKEN` permissions and does `actions/checkout` of `main`
    only.
  - The VM or container can reach only the token file and the network, with no other host mounts.
  - The CCP CI app and the alt character are both cheap to revoke. Revoking them is the
    recovery if something leaks.
- **Etiquette:** live tests make a handful of requests per run, honour the same limiter, and
  run at most daily.

### Weekly upstream watch (`.github/workflows/upstream-watch.yml`)

The job runs on a schedule (Mondays) and on manual dispatch, on a GitHub-hosted runner. It needs
no secrets. `Scripts/check-upstream.sh` compares `Spec/pins.json` with live metadata:

1. **ESI compatibility dates:** fetch `/meta/compatibility-dates` and flag any date newer than
   the pinned one.
2. **ESI changelog:** fetch `/meta/changelog` and keep only entries newer than the pinned date
   for the operations in the generator filter. Entries of type `removed` or breaking are
   highlighted.
3. **SDE:** read `/tranquility/latest/`. Flag a new release, changed version hashes for the
   tables we use (`mapSolarSystems`, …), and new entries in `_schemaChangelog` for those tables.
4. **Report:** if anything changed, open an issue titled `Upstream changes: ESI <date> / SDE
   <release>`, or comment on the open one. GitHub notifies watchers by email and app. Labels:
   `upstream`, plus `breaking` where it applies.

A later step could regenerate the code and open a draft PR. GitHub disables scheduled workflows
in public repos after 60 days without repo activity, so the job also notes in each issue when
the last commit was.

## 8. What ESI is for in Overseer's roadmap

- **Phase 1 (status line: system and security):** no ESI calls are needed. The system name comes
  from the Local chat log, and ID and security come from SDEKit. The character ID comes from the
  chat log file name.
- **Phase 2 (ship, docked state, online):** SSO with three scopes, then
  `/characters/{id}/location`, `/ship` and `/online`. Ship names come from SDE `types`, station
  names from SDE `npcStations`, and structure names from ESI `/universe/structures/{id}`.
- **Optional anytime:** corp and alliance tickers in labels, from public `GET /characters/{id}`
  and `POST /universe/names`, plus portraits from the image server.
- **Later ideas, not planned:** fleet membership (`esi-fleets.read_fleet.v1`) to build cycle
  groups automatically. Roadmap phases 2–6 (hotkeys, layouts, minimizing, profiles, game-log
  alerts) need no ESI.

So 0.1 ships no ESIKit code. ESIKit arrives in 0.2, together with SSO.

## 9. Decisions

| # | Decision | Chosen | Rejected and why |
|---|---|---|---|
| D1 | Name | **CapsuleerKit**; modules `CapsuleerCore`, `ESIKit`, `SDEKit` | EVEKit: taken by dead EVE projects, one letter from Apple's `EventKit`, and "EVE" is a CCP mark (licence §7.3). NewEdenKit: an active C# library with the same scope. |
| D2 | ESI and SDE in one package | **One package, separate modules** | Two packages would duplicate the transport and cache or need a third package. |
| D3 | Static data source | **SDE over HTTP** | ESI `/universe/systems` (removed at 2026-11-19); pinning an old compatibility date (no end date published). |
| D4 | ESI endpoint layer | **swift-openapi-generator, output committed, internal, wrapped by a hand-written facade** | Build plugin: Xcode trust prompt, slower builds, consumers resolve the generator. Fully hand-written: scales badly. |
| D5 | Platforms | **macOS 13; iOS and Linux deferred**, with porting seams kept | Linux in 0.1: extra CI and Foundation differences, with no consumer and no CI cost benefit on a public repo. |
| D6 | SSO redirect | **Supplied by the app.** Overseer: a custom URL scheme via `ASWebAuthenticationSession`. CLI: loopback. | Loopback for Overseer: needs a fixed registered port and a local listener. |
| D7 | Scope of 0.1 | **SDE only:** CapsuleerCore + SDEKit (solar systems). ESIKit is designed now and built in 0.2. | Shipping the ESI pipeline in 0.1 without a consumer. |
| D8 | Caching | Our own `CacheStore` (memory, disk, tiered), keyed by identity; URLCache disabled | URLCache: opaque and can't key by character. |
| D9 | Repo | **Own public repo `Crazor/CapsuleerKit` from the start**; Overseer uses a remote package reference | Living inside Overseer: no CI or weekly job of its own, and a later subtree split. |
| D10 | Licence | MIT plus CCP notice | — |
| D11 | Concurrency | Swift 6 mode (data-race checking); `Sendable` final classes with internal actors | A public actor API would force `await` hops onto library isolation. |
| D12 | CI | Hosted macOS for every push and PR; live authenticated tests (0.2) on an ephemeral self-hosted runner (Tart VM or Linux container, decided in 0.2), triggered only by schedule, dispatch or push to `main` | Refresh token in GitHub secrets: needs write-back on rotation, and leaks are more likely. |
| D13 | Upstream watch | Weekly job that diffs ESI compatibility dates and changelog and the SDE manifest against `Spec/pins.json`, and opens an issue | Manual checking. |
| D14 | Logging | Own `LogSink` protocol with `os.Logger` and stderr sinks | swift-log: an extra dependency for little gain. |
| D15 | 0.2 scope | **Everything Overseer phase 2 needs:** ESIKit pipeline, SSO and tokens, `location` / `ship` / `online`, structure names (`esi-universe.read_structures.v1`), station names via `POST /universe/names`, ship type names via SDE `types` records | Splitting into 0.2 and 0.3. |
| D16 | Names | NPC station names come from ESI `POST /universe/names` (the SDE `npcStations` table has no names). Ship type names come from single SDE `types` records (immutable, cached), not the whole `types` table. | Downloading the full `types` table for a handful of ship names. |
| D17 | Authenticated live tests | Written in 0.2 and run locally (`capsuleer login`, `CAPSULEER_LIVE_AUTH=1`); the isolated self-hosted runner is a follow-up after 0.2 | Setting up Tart or a Linux container runner inside 0.2. |
| D18 | Rate-limit plumbing | ESIKit passes the spec's rate-limit group, identity and idempotency to `ESIEtiquetteTransport` as internal request headers (`X-CapsuleerKit-*`), which the transport strips before sending | Task-locals: implicit and fragile across the coalescing task. |
| D19 | JWT keys | Verify both RS256 and ES256, since EVE's JWKS publishes both | RS256 only. |
| D20 | Callback URLs | Follow developers.eveonline.com's rules: `https`, `http` for localhost only, or a custom scheme `eveauth[a-z0-9+.-]*` ending in a letter or digit (Overseer: `eveauth-overseer://callback`). `SSOConfiguration.isAcceptedCallbackURL(_:)` checks this, and `WebAuthenticationSession` refuses other schemes before opening the sheet. | Any custom scheme: the portal rejects it at registration. |
