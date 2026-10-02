# AI News — macOS App Architecture

A personal, single-user native macOS app that collects tech and AI headlines
from Asian sources, so that no US-centric aggregator sits between the reader
and the publisher. Headlines are stored locally; reading happens on the
publisher's own page, in the user's own browser.

This document describes the **native macOS app only**. An earlier
browser-based version was superseded by this one; it is not part of this
repository and is not developed further.

---

## 0. Target Environment

Verified on the development machine, and the baseline this document assumes:

| Component | Version |
|---|---|
| macOS | 26.6.2 (Tahoe), build 25G83, Apple silicon |
| Xcode | 26.6 (build 17F113) |
| Swift | 6.3.3 (swiftlang-6.3.3.1.3) |
| SDK | macOS 26.5 (`-sdk macosx26.5`) |
| Deployment target | macOS 26.0 |
| Language mode | Swift 6, strict concurrency |
| Third-party dependencies | **none** |

Consequences that shape everything below:

- **Swift 6 strict concurrency is on.** Every value crossing a task boundary is
  `Sendable`. The engine is an `actor`; UI state is `@MainActor`.
- **Observation, not ObservableObject.** `@Observable` with `@State` /
  `@Environment`.
- **SwiftData, not Core Data.** `@Model` classes with `#Unique`.
- **Swift Testing, not XCTest.** `@Test` / `#expect`.
- **No Homebrew, no XcodeGen, no Tuist.** Anything needing a package manager
  must be Xcode-native or hand-written. The project therefore hand-writes its
  `.pbxproj` and uses **synchronized folder groups** (Xcode 16+), so the file
  list never needs maintaining.
- **Zero dependencies is achievable** because v1 consumes feeds, not HTML — see
  §5. `XMLParser` in Foundation is enough.

---

## 1. Goals & Non-Goals

### Goals
- Native SwiftUI macOS app. One window. No server process, no localhost socket, no browser needed to aggregate.
- Collect headlines from Asian sources: China, Taiwan, Japan, Korea, India, Singapore.
- **Feeds only, never article pages.** The app reads a source's published feed and nothing else.
- **Show headlines in English** using Apple's on-device translation, while keeping the publisher's original words one glance away (§7.5).
- Click-through opens the publisher's own page in the user's default browser — real human traffic.
- Resilient: sources can be parked inactive, per-source cooldowns, automatic deactivation after repeated failure.
- Polite by construction: strictly serial fetching, randomised delays, no aggressive crawling, no cookie retention.
- Headlines persist locally and stay readable with no network at all.

### Non-Goals
- Full-text extraction or summarisation. (Headline translation **is** in scope — see §7.5. The webapp listed translation as a non-goal; that is deliberately reversed here, because a reader who cannot read Chinese, Japanese or Korean otherwise skips the sources that matter most.)
- Multi-user support, accounts, or cloud sync.
- Background or scheduled fetching. **Every run is started by a human** (see §13 D6).
- iOS / iPadOS.
- App Store distribution, notarisation, or code signing for distribution.
- HTML scraping **wired into the app** in v1: `ScrapeFetcher` is written and tested, but the engine still reports scrape sources as not implemented. Enabling it for all 13 feed-less sources at once is what §14 defers.
- Any further work on the earlier browser-based version.

---

## 2. High-Level Architecture

One process, four layers. There is no client/server split and no HTTP API —
what used to be `POST /api/fetch` is now a method call on an actor.

    ┌───────────────────────────────────────────────────────────────┐
    │  PRESENTATION — SwiftUI, @MainActor                           │
    │                                                               │
    │   WindowGroup                                                 │
    │     NavigationSplitView                                       │
    │       sidebar → SourceListView  (rank, badge, INACTIVE, dim)  │
    │       detail  → HeadlineListView (grouped by source)          │
    │     Settings scene → Cooldowns / Behaviour                    │
    │                                                               │
    │   • Renders state; performs no network I/O                    │
    │   • Opens links via NSWorkspace.shared.open(_:)               │
    └───────────────────────────┬───────────────────────────────────┘
                                │ observes
    ┌───────────────────────────▼───────────────────────────────────┐
    │  APP STATE — @MainActor @Observable                           │
    │                                                               │
    │   AggregatorStore                                             │
    │     • sources, headlines, run progress, summary               │
    │     • owns the Task handle for start / stop                   │
    └───────────────────────────┬───────────────────────────────────┘
                                │ await engine.run(...) → events
    ┌───────────────────────────▼───────────────────────────────────┐
    │  AGGREGATION — actor AggregationEngine                        │
    │                                                               │
    │   Serial loop, one source at a time:                          │
    │     1. skip if inactive                                       │
    │     2. skip if no feedURL                                     │
    │     3. skip if inside cooldown                                │
    │     4. fetch the feed                                         │
    │     5. parse → items                                          │
    │     6. upsert (dedup by URL)                                  │
    │     7. update lastFetchedAt / lastAttemptedAt                 │
    │     8. apply failure policy (§6)                              │
    │     9. Task.sleep(random 5–10s)                               │
    │   Honours cancellation at every await.                        │
    └──────┬─────────────────────────────────────┬──────────────────┘
           │                                     │
    ┌──────▼────────────────────────────────────────────────────────┐
    │  SourceFetcher — strategy router                              │
    │                                                               │
    │    feedURL != nil           → FeedFetcher    [v1, implemented]│
    │    headlineSelector != nil  → ScrapeFetcher  [seam, see §14]  │
    │    neither                  → warn(.noSource) → skip          │
    │                                                               │
    │   ┌─────────────────────┐    ┌─────────────────────────────┐  │
    │   │ HTTPClient          │    │ FeedParser                  │  │
    │   │ URLSession          │    │ XMLParser (Foundation)      │  │
    │   │ .ephemeral, 10s     │    │ RSS 2.0 · RSS 1.0 · Atom    │  │
    │   │ 3 redirects, UA     │    │ → [ParsedItem]              │  │
    │   └─────────────────────┘    └─────────────────────────────┘  │
    └───────────────────────────────────────────────────────────────┘
           │
    ┌──────▼────────────────────────────────────────────────────────┐
    │  LOCALISATION — TranslationCoordinator  (@MainActor)          │
    │                                                               │
    │   Apple Translation framework. On-device, offline, no service.│
    │   Runs while the engine sleeps between sources, so it costs   │
    │   no wall-clock time the run was not already spending.        │
    │   Writes translatedTitle back onto each Headline, once, ever. │
    └───────────────────────────┬───────────────────────────────────┘
                                │
    ┌───────────────────────────▼───────────────────────────────────┐
    │  PERSISTENCE — SwiftData ModelContainer                       │
    │    ModelContainer(for: Source.self, Headline.self)            │
    │    ~/Library/Application Support/AINews/AINews.store          │
    └───────────────────────────────────────────────────────────────┘

**There is no scheduler, no timer, and no launch agent.** The loop runs only
while a human-initiated run is in progress.

---

## 3. Component Responsibilities

### Presentation (SwiftUI)
| Responsibility | Detail |
|---|---|
| Rendering | Source sidebar, headline list, progress, run summary |
| Navigation | `NavigationSplitView`; list selection drives the detail pane |
| Link handling | `NSWorkspace.shared.open(url)` — default browser |
| Appearance | Follows the system light/dark automatically; no custom palette |
| Controls | Start / Stop, per-source "Fetch now", Mark All Read, Reload Sources |
| Never | Does no networking and no parsing |

### App State (`AggregatorStore`)
| Responsibility | Detail |
|---|---|
| Run lifecycle | Owns the running `Task`; start and stop only — no pause in v1 |
| Progress | Current source, index/total, next-fetch countdown, live summary |
| Data access | `ModelContext` reads for the UI; maps models to view types |
| Event bridge | Consumes engine events, republishes as observable state |
| Preferences | `@AppStorage` for cooldown and jitter settings |

### Aggregation (`AggregationEngine`, actor)
| Responsibility | Detail |
|---|---|
| Serialisation | One source in flight at a time, enforced by actor isolation |
| Cooldown | Refuses to re-fetch inside the window, before any network work |
| Pacing | Randomised 5–10s delay between sources |
| Failure policy | Applies §6 and persists the outcome |
| Cancellation | Checks `Task.isCancelled` at every suspension point |
| Purity | Imports no SwiftUI; fully testable with no network |

### SourceFetcher (strategy router)
| Responsibility | Detail |
|---|---|
| Routing | Picks the strategy per source: feed if `feedURL` exists, scrape if a selector exists, otherwise warns |
| Extensibility | The engine depends only on the `SourceFetching` protocol, so adding scraping changes no engine code |
| Isolation | Every strategy returns the same `[ParsedItem]` — callers cannot tell which was used |

### FeedFetcher (v1 strategy)
| Responsibility | Detail |
|---|---|
| Transport | `HTTPClient` (`URLSession`, `.ephemeral` config) |
| Limits | 10s request timeout, max 3 redirects, no automatic retries |
| Identity | Descriptive `User-Agent` (§8) |
| Privacy | Ephemeral session — no cookies stored, nothing cached to disk |
| Formats | RSS 2.0, RSS 1.0 / RDF, and Atom — all three appear in the seed list |
| Mechanism | Foundation `XMLParser` with a small element-stack state machine |
| Extract | Item title + link, and the published date when present |
| Reject | Empty titles, `javascript:`/`mailto:` links, duplicates within one feed |

### ScrapeFetcher (not implemented in v1)
| Responsibility | Detail |
|---|---|
| Status | **Designed, not built.** The protocol conformance and routing already exist; the type does not |
| Future work | Fetch the homepage, apply `headlineSelector`, return the same `[ParsedItem]` |
| Why it matters now | The router, the model field and the warning path are all in place, so adding it later touches no engine code |

### TranslationCoordinator (`@MainActor`, `@Observable`)
| Responsibility | Detail |
|---|---|
| Engine | Apple's Translation framework — on-device, offline, no account, no key, no network |
| Trigger | Flagged after each source is fetched, and at launch for anything left pending |
| Batching | Pending headlines grouped by source, because a batch mixing Chinese and Japanese would leave the framework guessing |
| Session | SwiftUI only vends a session through `.translationTask`, so the window hosts it and the coordinator drains the queue |
| Persistence | Writes `translatedTitle` once per headline; the URL unique constraint means each is translated at most once, ever |
| Failure | Marks the batch terminal rather than retrying forever |

### Persistence (SwiftData)
| Responsibility | Detail |
|---|---|
| Source state | Rank, URLs, cooldown, inactive flag, failure counters, audit fields |
| Headlines | Deduplicated by URL, with first-seen and last-seen timestamps |
| Durability | Survives relaunch; readable with no network |

---

## 4. Data Model

Two `@Model` classes. `#Unique` gives SwiftData a real uniqueness
constraint, which is what makes the upsert in §5 safe.

    import Foundation
    import SwiftData

    @Model
    final class Source {
        #Unique<Source>([\.id])

        var id: String                  // from source_id in sources.json; the stable identity
        var name: String
        var url: URL                    // homepage — for display and click-through only
        var feedURL: URL?               // the ONLY thing the app fetches
        var status: String              // "ready" | "needs_custom_scraper" | "ready_via_third_party"
        var isInactive: Bool            // mirrors "inactive" in sources.json
        var note: String
        var rank: Int                   // 1-based editorial order; lower = higher priority

        var cooldownMinutes: Int = 60
        var headlineSelector: String?   // reserved for future HTML scraping; always nil in v1

        var consecutiveFailures: Int = 0
        var lastFetchedAt: Date?
        var lastAttemptedAt: Date?
        var deactivatedAt: Date?
        var deactivationReason: String?
    }

    @Model
    final class Headline {
        #Unique<Headline>([\.url])

        var url: URL                    // canonical article URL — the dedup key
        var title: String
        var sourceID: String
        var publishedAt: Date?          // from the feed, when the feed provides it
        var fetchedAt: Date             // first seen by this app
        var lastSeenAt: Date            // refreshed when it reappears in the feed
        var isRead: Bool

        // Translation. The original title is never overwritten: headline text
        // is compressed and dense with proper nouns, and machine translation
        // mangles both often enough that the source must stay available.
        var translatedTitle: String?    // English, when one was produced
        var translationState: String?   // nil = pending; done | skipped | failed
        var detectedLanguage: String?   // what the framework detected
    }

### Why `URL` and not `String`
`URL` gives free validation and correct comparison, and SwiftData persists it
natively. The cost is that one malformed seed row throws at insert time, so the
importer must validate and **skip** bad rows rather than abort the import.

### Field notes
| Field | Notes |
|---|---|
| `id` | Comes from `source_id` in `sources.json` and is **never derived from the display name**. Headlines reference it, so it is the one value that must not drift. A name-derived id was tried and was destructive: renaming a source changed its id, the importer saw an unknown source, inserted a duplicate, and deleted the original along with every headline it owned |
| `rank` | Taken from the order of `sources.json` — the AI-first ranking is already encoded there and must not be re-sorted |
| `isInactive` | Seeded from `inactive` in `sources.json` **on insert only**. After that the app owns it: a re-import must never reapply the JSON value, or the sidebar's Skip silently reverts at the next launch. This is the one editorial field the user also owns |
| `feedURL` | `nil` means "scrape-only source" — the engine skips it with a distinct reason (§5) |
| `headlineSelector` | Always `nil` in v1. Kept so the schema does not need migrating when scraping is added |
| `status` | Preserved verbatim from the JSON; drives the RSS/SCRAPE badge |
| `publishedAt` | Optional: some feeds omit dates or use malformed ones. Never fail a parse over a bad date |
| ordering | `orderingDate` is `publishedAt ?? fetchedAt`, and is the single definition used for both sorting and retention. It is deliberately **not** `lastSeenAt`: upsert refreshes that on every run for every headline still present in a feed, so it collapses onto the run timestamps and carries no ordering information at all |

---

## 5. Service Interfaces

The webapp expressed this as an HTTP API. Native, it is plain Swift. These
protocols exist so the parser and engine can be unit-tested without a network.

    struct SourceSnapshot: Sendable, Hashable {
        let id: String
        let name: String
        let url: URL
        let feedURL: URL?
        let rank: Int
        let cooldownMinutes: Int
        let isInactive: Bool
        let lastAttemptedAt: Date?
        let lastFetchedAt: Date?
    }

    struct ParsedItem: Sendable, Hashable {
        let title: String
        let url: URL
        let publishedAt: Date?
    }

    /// One strategy per source. The engine knows only this protocol, so a new
    /// strategy (HTML scraping, JSON Feed, an API) needs no engine change.
    protocol SourceFetching: Sendable {
        func items(for source: SourceSnapshot) async throws -> [ParsedItem]
    }

    /// Picks a strategy. v1 always resolves to .feed or .none; the .scrape case
    /// is already routed and only awaits a conformance (see §14).
    enum FetchRoute: Sendable {
        case feed(URL)                            // implemented in v1
        case scrape(homepage: URL, selector: String)   // seam — no conformer yet
        case none(reason: String)                 // no feed and no selector: warn and skip
    }

    struct FetchRouter: Sendable {
        static func route(_ source: SourceSnapshot) -> FetchRoute {
            if let feed = source.feedURL { return .feed(feed) }
            if let sel = source.headlineSelector, !sel.isEmpty {
                return .scrape(homepage: source.url, selector: sel)
            }
            return .none(reason: "no feed and no selector")
        }
    }

### Engine surface

    actor AggregationEngine {
        enum Event: Sendable {
            case willFetch(sourceID: String, index: Int, total: Int)
            case fetched(sourceID: String, newCount: Int, totalInFeed: Int)
            case skipped(sourceID: String, reason: SkipReason)
            case warned(sourceID: String, warning: Warning)   // non-fatal; run continues
            case failed(sourceID: String, detail: String)     // fatal to this run only
            case finished(Summary)
        }

        enum SkipReason: Sendable {
            case inactive
            case noFeed                  // scrape-only source; nothing to fetch in v1
            case cooldown(remaining: TimeInterval)
        }

        /// Non-fatal problems. v1 warns, counts and moves on — it never
        /// deactivates (§6). These are the states the UI must surface.
        enum Warning: Sendable, Equatable {
            case noSource(String)        // no feed and no selector
            case blocked(Int)            // 403 / 429
            case serverError(Int)        // 5xx
            case unreachable(String)     // timeout, DNS, TLS
            case emptyFeed               // parsed cleanly, zero items
            case notImplemented(String)  // .scrape route, no conformer yet
        }

        struct Summary: Sendable {
            var checked: Int
            var skipped: Int
            var failed: Int
            var newHeadlines: Int
        }

        func run(_ sources: [SourceSnapshot],
                 emit: @Sendable (Event) -> Void) async
    }

`.noFeed` is deliberately distinct from `.inactive`: a scrape-only source is
not dead, it is unsupported. The UI must show them differently, or the 13
feed-less sources will look like failures.

### Error taxonomy

    enum FeedError: Error, Sendable, Equatable {
        case http(Int)          // 403, 429, 5xx — status preserved for the policy table
        case timedOut
        case transport(String)  // TLS, DNS, offline
        case parseFailed(String)
        case emptyFeed          // parsed cleanly, zero items — usually a format change
    }

`http(Int)` deliberately keeps the status code, because §6 treats 403/429 (an
explicit block signal) completely differently from a 500.

---

## 6. Failure Handling & Auto-Deactivation

**v1 policy: warn and ignore. Nothing is auto-deactivated.**

While HTML scraping does not exist, a source that cannot be read is not broken —
it is simply unreachable *by the only strategy currently implemented*. Marking
it inactive would be a destructive, premature judgement about a source that may
work perfectly once scraping lands. So v1 never deactivates automatically.

| Condition | Action | Surfaced as |
|---|---|---|
| No `feedURL` | Skip, warning | `no source (see §14)` |
| 403 / 429 | Skip, warning | `blocked (HTTP 403)` |
| 5xx | Skip, warning | `server error (HTTP 500)` |
| Timeout / transport error | Skip, warning | `unreachable` |
| `emptyFeed` (0 items parsed) | Skip, warning | `empty feed (format change?)` |
| Success | Reset `consecutiveFailures` = 0 | — |

Every one of these increments `consecutiveFailures` so the problem is *visible
and countable*, and sets a transient `lastWarning` + `lastWarningAt` for the
UI. None of them writes `isInactive`.

### Auto-deactivation (designed, off in v1)
The thresholds below are implemented behind a setting that **defaults to off**.
They exist so the mechanism is designed rather than bolted on later:

| Failure type | Would deactivate at |
|---|---|
| 403 / 429 | immediately (explicit block signal) |
| `emptyFeed` | 3 consecutive |
| 5xx | 5 consecutive |
| Timeout / transport | 10 consecutive |

When enabled, deactivation sets:

    source.isInactive = true
    source.deactivatedAt = .now
    source.deactivationReason = "auto: <reason>"

> Keep the two causes distinguishable. `deactivationReason` beginning with
> `auto:` is machine-driven; anything else is the user's editorial decision
> (including sources parked inactive in `sources.json`). Never let the failure
> counter overwrite a human's reason, and never let a human's toggle be silently
> reverted by a later successful run.
>
> **v1 never writes `isInactive` at all.** The only writer is the user.

---

## 7. UI Behaviour Spec

### Window layout

    ┌────────────────────┬──────────────────────────────────────────────┐
    │ SOURCES            │  HEADLINES                                   │
    │                    │                                              │
    │ 1  机器之心    SCRAPE │  ▸ IT之家                        2m ago    │
    │ 2  量子位      SCRAPE │      Changan Auto delivers 228,900 vehicles  │
    │ 3  新智元      SCRAPE │      长安汽车 9 月交付 22.89 万辆            │
    │ …                  │      Another headline…                       │
    │ 8  DIGITIMES   SCRAPE │                                              │
    │ 10 日経クロステック RSS │  ▸ DIGITIMES                    14m ago    │
    │                    │                                              │
    ├────────────────────┴──────────────────────────────────────────────┤
    │ ▶ Start  7 / 30 · IT之家 · next in 6s · translating  [======----]  │
    └───────────────────────────────────────────────────────────────────┘

The translated headline is the first line; the publisher's own words sit
directly beneath it in a dimmer, smaller face. A toolbar toggle (Originals)
swaps them, and translation can be switched off entirely in Settings.

### Source rows
- Rank number, name, and the RSS/SCRAPE badge carried over from `sources.json`.
- Inactive sources are dimmed and badged `INACTIVE`.
- Feed-less sources are visibly distinct from inactive ones — badged by their
  `SCRAPE` status and skipped with reason "no feed", never hidden.
- Context menu: Fetch now · Enable/Disable · Open homepage · Copy URL.

### Headline list
- Grouped by source, newest first, in the ranked source order.
- Each headline shows its title and a relative timestamp.
- A single click opens the publisher's page via `NSWorkspace.shared.open(_:)`.
  **No in-app web view.**
- Unread items since the last session are marked; "Mark All Read" in the toolbar.

### Run lifecycle
1. Launch → SwiftData loads → cached headlines render immediately. No spinner.
2. Nothing is fetched until the user presses **Start**.
3. Sources iterate in `rank` order, strictly serially.
4. Per source: success renders new headlines inline; skip/failure shows a badge
   and **always advances to the next source**. One bad source never blocks a run.
5. Between sources, wait `5000 + Int.random(in: 0...5000)` ms.
6. On completion, show `N checked · M skipped · K failed · J new`.

### Translation behaviour

- **Engine**: Apple's Translation framework. On-device and offline. No service, no API key, no billing, no account, and no headline ever leaves the Mac.
- **When**: flagged after each source is fetched, so the work overlaps the 5-10s politeness pause the engine is already spending. Translating everything in one batch at the end of a run was rejected: it leaves the list unreadable for the whole run and loses all of it to a single failure.
- **Batching**: pending headlines are grouped **by source** and translated one source at a time, because a batch mixing Chinese and Japanese would leave the framework guessing which language applies.
- **Once, ever**: the result is written onto the Headline. Because headlines dedupe by URL, each is translated at most once for the lifetime of the store, so a second run translates only genuinely new items.
- **Never destructive**: the original title is retained. Headlines are compressed, pun-heavy and dense with proper nouns, and machine translation mangles company and product names often enough that a bad translation must never be the only thing on screen.
- **Skipping**: text already in English is marked `skipped` rather than stored, so it does not render a pointless duplicate line. A cheap ASCII check avoids the obvious cases before a session is even opened.
- **Failures are terminal**: a failed batch is marked `failed` rather than retried indefinitely, so one bad run cannot pin the CPU retranslating the same headlines.
- **Detection, not metadata**: the source language comes from the framework's own detection rather than a per-source language field, so nothing needs maintaining when a publisher changes language.

### Retention and display bounds

Two independent limits, because they solve different problems.

| Bound | Default | Purpose |
|---|---|---|
| Shown per source | 100 | The list is a news list, not an archive. Uncapped it becomes unreadable long before it becomes slow |
| Retained per source | 200 | Bounds the store and the in-memory fetch permanently. Feeds limit only what is *added* per run, never what accumulates |

- **Kept above shown on purpose**: a headline that scrolls out of a feed's window is still remembered as seen, so it is not re-added and re-translated weeks later.
- **Hidden is reported, never silent**: a truncated group shows `100 of 340` in its header rather than quietly dropping rows.
- **Display cap is applied in the view**, after sorting, so it takes the newest slice. Retention is applied on insert, per source, ordered by `orderingDate`.
- Measured growth on the reference machine: 504 headlines on the first run, **+116 eighty-five minutes later**. At that rate an unbounded store reaches thousands within weeks.

### Cancellation
- **Stop** cancels the task immediately. An in-flight request is cancelled and
  that source is **not** counted as a failure and **not** deactivated.
- Progress survives relaunch: persist the completed source ids and index so an
  interrupted run can be resumed.

---

## 8. Politeness Rules

Non-negotiable, and the reason this app fetches so little.

- **User-Agent**, descriptive and honest:
  `AINews/1.0 (personal feed reader; +https://github.com/kuyawa/ainews)`
- **Timeout**: 10s per request. No automatic retries.
- **Redirects**: follow at most 3.
- **Concurrency**: strictly 1. Never two feeds in parallel, ever.
- **Cooldown**: 60 minutes per source by default, enforced before any network work.
- **Feeds only.** Never an article URL. The client should assert that the URL it
  is about to fetch equals the source's registered `feedURL`.
- **Ephemeral session**: no cookies, no credential storage, no disk cache.
- **Manual runs only**: because a human starts every run, the app cannot
  accidentally become a crawler left running overnight.
- **Conditional requests**: send `If-None-Match` / `If-Modified-Since` when
  the server previously supplied an ETag or Last-Modified. A 304 is a success,
  not a failure, and must not disturb the failure counter.

---

## 9. macOS Integration Points

Where a native app differs from the web version, and where the surprises live.

### App Transport Security — the one real blocker
The default ATS policy refuses plain `http://` URLs, and **one seed feed is
plain HTTP**:

| Source | Feed | Note |
|---|---|---|
| 雷锋网 (Leiphone) | `http://www.leiphone.com/feed/` | Plain HTTP — ATS refuses it unless excepted |

So `Info.plist` needs a **narrow** exception — never a blanket
`NSAllowsArbitraryLoads`:

    NSAppTransportSecurity
      NSExceptionDomains
        leiphone.com
          NSExceptionAllowsInsecureHTTPLoads = true

Note that 甲子光年's *homepage* is also plain HTTP (`http://www.jazzyear.com`),
but its **feed** is HTTPS (`werss.bestblogs.dev`). Since v1 fetches feeds only,
no exception is needed for it today — add one only if HTML scraping is ever
enabled (§14).

### Sandboxing — off
The app is **not sandboxed** (decision D4). It is a personal tool, not App Store
bound, and this avoids a class of silent networking failures. If it is ever
sandboxed, both of these become mandatory:

    com.apple.security.network.client = true

### Opening links
`NSWorkspace.shared.open(url)` — the user's default browser, with their
extensions, password manager and cookie jar intact.

### App Nap
Wrap a run in
`ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason:)` or
macOS may throttle the jitter sleeps and the run will crawl. End the activity
when the run finishes **or is cancelled** — leaking it keeps the Mac awake.

### Deliberately not used
`NSBackgroundActivityScheduler`, `SMAppService` launch-at-login, and
`MenuBarExtra` are all **out of scope for v1** (decision D6). Do not add them
speculatively.

---

## 10. Build & Run

    # Build
    xcodebuild -project AINews.xcodeproj -scheme AINews -configuration Debug build

    # Run
    open AINews.xcodeproj      # then ⌘R

Project conventions:
- **Xcode 26.6**, one app target, one test target.
- **Synchronized folder groups** (Xcode 16+): the project references *folders*,
  so adding a Swift file requires no `.pbxproj` edit. This is what makes a
  hand-written project file maintainable.
- `sources.json` ships as a **bundled resource**, imported on first launch.
- The SwiftData store lives in `Application Support/AINews/` — never inside
  the app bundle, which may be read-only or replaced on rebuild.

---

## 11. Tech Stack

| Layer | Choice | Rationale |
|---|---|---|
| Language | Swift 6.3, Swift 6 language mode | Strict concurrency catches data races at compile time |
| UI | SwiftUI | Native, declarative, no build step |
| State | Observation (`@Observable`) | Modern replacement for ObservableObject |
| Concurrency | async/await + actor isolation | Replaces the webapp's timers and state machine |
| Persistence | SwiftData | Native, schema-migratable, no SQL boilerplate |
| Feed parsing | Foundation `XMLParser` | Handles RSS 2.0, RSS 1.0 and Atom; **no dependency needed** |
| Networking | URLSession, ephemeral config | No dependency needed |
| Logging | `os.Logger` (Unified Logging) | Filterable in Console.app; no log files to rotate |
| Translation | Apple Translation framework | On-device and offline: no service, no key, no billing, and no third party ever sees a headline |
| Tests | Swift Testing | `@Test` / `#expect`, built into Xcode 26 |
| Dependencies | **none** | System frameworks only |

---

## 12. Security & Privacy

- No accounts, no analytics, no telemetry, no third-party crash reporting.
- Outbound requests go only to the 17 registered feed URLs.
- **Translation never leaves the machine.** It uses the system framework, not a cloud API. Routing headlines through Google, DeepL or an LLM would put a third party back between the reader and the publisher, which is the exact thing this app exists to remove.
- Article reading happens in the user's browser, never in the app.
- Ephemeral URLSession: no cookies persisted, nothing to leak.
- Logs contain source id, status code and counts — never feed content.
- The app stores no credentials. There are none to store.
- `sources.json` is bundled read-only; runtime state lives in SwiftData.

---

## 13. Decisions

Resolved with the user before implementation. These are settled — do not
silently revisit them.

| # | Decision | Choice | Consequence |
|---|---|---|---|
| D1 | App name / bundle id | Display name **AI News**, target `AINews`, id `net.kuyawa.ainews` | Product name has no space; the display name does |
| D2 | Project creation | **Hand-written** `.pbxproj` with synchronized folder groups | Repo is self-contained; no XcodeGen/Tuist needed |
| D3 | Fetch strategy | **Feeds only in v1**, scraping designed in from the start | 17 sources fetched, 13 warned and skipped; no HTML parser dependency yet, but the strategy seam, router and model fields all exist |
| D4 | Persistence | **SwiftData** | `@Model` + `#Unique`; no SQL layer |
| D5 | Sandboxing | **Off** | No entitlement friction; not App Store bound |
| D6 | Refresh model | **Manual only** | No scheduler, no login item, no menu bar extra |
| D7 | Link behaviour | **Default browser** | `NSWorkspace.shared.open(_:)`; no WKWebView |
| D8 | Deployment target | **macOS 26.0** | No availability guards needed |
| D9 | Headline selectors | **All `nil` in v1** | The field exists for the future; nothing reads it yet |
| D10 | `sources.json` authority | **Seeds a fresh install; reference material thereafter** | Applied when the store is empty, and re-applied only by an explicit Reload Sources. Importing on every launch made an edited or truncated file destructive, because the importer deletes sources absent from it along with their headlines |
| D11 | Broken / missing source | **Warn and ignore** — never auto-deactivate in v1 | Unreadable sources stay visible and countable; a human decides what is actually dead |
| D12 | Scraping readiness | **Designed in, not stubbed on** | `SourceFetching` + `FetchRouter` + `headlineSelector` exist in v1 so §14 is additive |
| D13 | Translation | **Apple on-device**, target English, original always retained | Offline and free; reverses the webapp's explicit non-goal |
| D14 | Source identity | **Explicit `source_id`** in `sources.json`, required | Display names are now freely editable; a missing or duplicate id is skipped and reported rather than guessed |

---

## 14. Future Work

- **Wire `ScrapeFetcher` into the app.** It is written and tested, but the
  engine still short-circuits scrape routes as not implemented. What remains is
  the opt-in below; without it, enabling scraping fires 13 unchecked homepage
  requests at once.
- **Per-source opt-in for scraping.** `headlineSelector` is the natural place
  for it — today it would mean "this source may be scraped", and once an HTML
  parser lands it becomes the CSS selector it was named for.
- **A proper HTML parser** (SwiftSoup via SPM) if the heuristic proves too
  blunt. Ranked against three real homepages, `ScrapeFetcher` returns 29 / 7 /
  67 headlines and no navigation, after filters for article shape,
  tracking-query duplicates and site furniture. It cannot read a
  JavaScript-rendered homepage, and it may still surface an occasional promo
  block — both of which a real parser with per-site selectors would fix.
- Selector editor in Settings with a live preview against the fetched homepage,
  which doubles as the tool for tuning a source that the heuristic handles
  badly.
- Per-source keyword filters (e.g. only headlines matching "AI").
- Failure-counter decay, so a transient outage does not permanently kill a source.
- Scheduled background refresh via `NSBackgroundActivityScheduler` (D6 deferred
  this, it is not rejected).
- Optional daily digest notification.
- Export/import of the headline store.
