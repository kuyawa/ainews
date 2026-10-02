# Build Task: AI News — native macOS app

Build a personal, single-user macOS app that collects tech and AI headlines
from Asian sources so that no US-centric aggregator sits between the reader and
the publisher.

**Read `architecture.md` first — it is the source of truth.** If this file and
architecture.md disagree, architecture.md wins.

Target: **macOS 26 (Tahoe), Xcode 26.6, Swift 6.3, Swift 6 language mode, strict
concurrency, deployment target macOS 26.0, zero third-party dependencies.**

---

## What to build

One Xcode project containing a SwiftUI app. No server, no browser dependency,
no separate backend process.

### 1. Xcode project
Hand-write `macos/AINews.xcodeproj`. There is no XcodeGen or Tuist on this
machine, so a valid project file is a deliverable, not a prerequisite.

- App target `AINews`, plus a unit-test target `AINewsTests`.
- Use **synchronized folder groups** (Xcode 16+): reference the `AINews/`
  folder rather than enumerating files, so adding a Swift file needs no
  `.pbxproj` edit.
- Product name `AINews` (no space); `CFBundleDisplayName` = `AI News`;
  bundle identifier `net.kuyawa.ainews`.
- **Not sandboxed** (no `.entitlements` required).
- `Resources/sources.json` is a bundled resource, not a file reference.

### 2. Persistence — SwiftData
Two `@Model` classes exactly as specified in architecture.md §4: `Source`
and `Headline`, with `#Unique` on `Source.id` and `Headline.url`. Store
at `Application Support/AINews/AINews.store`.

### 3. Source importer
On first launch, import the bundled `sources.json` (30 entries, listed below).

- Preserve file order as `rank` (1-based). The order is an editorial AI-first
  ranking — **never re-sort it**.

- Each entry carries an explicit `source_id`. Use it verbatim as the row id.
  **Never derive an id from the display name** — headlines reference the id, so
  a name-derived one makes renaming destructive. Skip and report an entry whose
  `source_id` is missing, blank, or duplicated rather than guessing.
- Map `inactive` → `isInactive` (all 30 are currently `false`).
- Keep `status`, `note` and `feed_url` verbatim.
- `cooldownMinutes = 60`; `headlineSelector = nil` for all sources in v1.
- Re-importing must **upsert** by `id`: update name/url/feedURL/note/status/
  rank/isInactive, but **never clobber** `consecutiveFailures`,
  `lastFetchedAt`, `lastAttemptedAt`, `deactivatedAt` or
  `deactivationReason`.
- Expose it as a **Reload Sources** command so editing the JSON re-syncs the list.
- A malformed row must be skipped with a logged warning, never crash the import.

### 4. Fetch layer — build the seam, not just the feed path
The engine must depend on a strategy protocol, **not** on feed fetching
directly. Scraping is coming next; if the engine hardcodes feeds, that work
becomes a rewrite.

    protocol SourceFetching: Sendable {
        func items(for source: SourceSnapshot) async throws -> [ParsedItem]
    }

    enum FetchRoute: Sendable {
        case feed(URL)
        case scrape(homepage: URL, selector: String)   // routed, no conformer yet
        case none(reason: String)
    }

- `FetchRouter.route(_:)` picks the route: `feedURL` → `.feed`;
  else non-empty `headlineSelector` → `.scrape`; else `.none`.
- Implement **`FeedFetcher: SourceFetching`** (and its private `HTTPClient`).
- Do **not** implement `ScrapeFetcher`. Leave the `.scrape` case returning a
  clear "not implemented" warning so the seam is obvious and tested.
- `AggregationEngine` must not import or mention FeedFetcher or RSS. It takes
  a `SourceFetching`.

`HTTPClient` requirements:

- `URLSession` with an **`.ephemeral`** configuration — no cookie storage,
  no credential storage, no disk cache.
- `timeoutIntervalForRequest = 10`, `timeoutIntervalForResource = 20`.
- User-Agent from architecture.md §8.
- A `URLSessionTaskDelegate` capping redirects at 3.
- Map failures onto `FeedError`, **preserving HTTP status** in `.http(Int)`.
- Return raw `Data` — the client does not parse.
- **Assert the URL is the source's registered `feedURL`.** Never fetch an
  article URL.

### 5. Feed parser — no dependency
`FeedParser`, built on Foundation `XMLParser` with a small element-stack
state machine. It is used by `FeedFetcher` only — never by the engine.

It must handle all three formats present in the seed list:

| Format | Detected by | Items at | Title | Link | Date |
|---|---|---|---|---|---|
| RSS 2.0 | `<rss version="2.0">` | `/rss/channel/item` | `title` | `link` | `pubDate` |
| RSS 1.0 / RDF | `<rdf:RDF>` | `/rdf:RDF/item` | `title` | `link` | `dc:date` |
| Atom | `<feed xmlns=…Atom>` | `/feed/entry` | `title` | `link rel="alternate" href` | `updated` / `published` |

- **Detect the format from the document**, never from the file extension. The
  `fmt` column below is the expected value, not a contract.
- Handle CDATA, XML entities, and both `<link>text</link>` and
  `<link href="…"/>` shapes.
- Atom entries have **no text content in `<link>`** — read the `href`
  attribute of `rel="alternate"`.
- Dates: RFC 822 for RSS, ISO 8601 for Atom. **A malformed or missing date must
  not fail the parse** — store `publishedAt = nil` and carry on.
- Resolve relative link URLs against the feed URL.
- Drop empty/whitespace titles, `javascript:` and `mailto:` links, and
  duplicates within one feed.
- Return an empty array when nothing matched — the engine maps that to
  `FeedError.emptyFeed`, which counts toward auto-deactivation.

### 6. Aggregation engine
`actor AggregationEngine` with the `run(_:emit:)` surface in architecture.md §5.

For each source, in `rank` order, **strictly serially**:
1. Skip if `isInactive` → `.skipped(.inactive)`
2. Route via `FetchRouter`; if `.none` → `.warned(.noSource)` and continue
3. Skip if inside cooldown → `.skipped(.cooldown(remaining:))`
4. Fetch through the injected `SourceFetching`
5. Upsert (dedup on `url`; on conflict refresh `lastSeenAt`)
6. Set `lastFetchedAt` / `lastAttemptedAt`
7. Apply the **warn-don't-deactivate** policy in architecture.md §6
8. `try await Task.sleep(...)` for `5000 + Int.random(in: 0...5000)` ms

Cancellation is honoured at every `await`. A source cancelled mid-request is
**not** a failure and must **not** be deactivated.

### 7. App state
`@MainActor @Observable final class AggregatorStore` — owns the running
`Task`, exposes sources, grouped headlines, progress
(`current source`, `index/total`, `next fetch in Ns`) and the final summary.
Consumes engine events and republishes them as observable state.

### 8. UI
- `NavigationSplitView`: source sidebar (rank, name, RSS/SCRAPE badge, dimmed
  plus `INACTIVE` badge when inactive) | headline list grouped by source.
- Toolbar: Start / Stop, Mark All Read, filter to unread, Reload Sources.
- Progress bar pinned at the bottom: `7 / 30 · current: IT之家 · next in 6s`.
- Summary line at the end: `N checked · M skipped · K failed · J new`.
- Settings: cooldown minutes and jitter range.
- A headline click opens `NSWorkspace.shared.open(url)`. **No in-app web view.**
- Follows system light/dark automatically. No custom palette.

### 9. Translation into English

Headlines arrive in Chinese, Japanese and Korean. Translate them locally.

- **Use Apple's Translation framework.** On-device and offline. No cloud
  service, no API key, no billing, and no headline may leave the Mac — routing
  them through a third party would defeat the point of reading publishers
  directly.
- **The session comes from SwiftUI only.** `.translationTask(config)` is the
  only way to obtain a `TranslationSession`, so the window hosts the modifier
  and the coordinator drains a queue when the configuration is (in)validated.
  This needs `import Translation` in that file: the modifier lives in the
  `_Translation_SwiftUI` cross-import overlay, which only activates when a
  file imports both SwiftUI and Translation.
- **When**: schedule after each source is fetched, so translation overlaps the
  5-10s politeness pause. Do not fetch everything and translate in one batch at
  the end.
- **Batch by source**, one `translations(from:)` call per source: a batch
  mixing Chinese and Japanese leaves the framework guessing.
- **Translate once, ever.** Store the result on the Headline. The URL unique
  constraint means a headline is never translated twice across runs.
- **Never overwrite the original.** Show the translation first and the
  publisher's own words beneath it, with a toolbar toggle to swap them.
- **Skip text already in English** rather than storing it, so no pointless
  duplicate line renders. Detect the source language from the framework's own
  response; do not add a per-source language field to `sources.json`.
- **Failures are terminal.** Mark a failed batch failed; never retry it in a
  loop.
- Keep the **policy** (what to do with a result) in a pure, nonisolated function
  so it can be unit tested — a `TranslationSession` cannot be constructed in a
  test.
- `TranslationSession` and `Request` are not annotated `Sendable`. A
  `preconcurrency` import plus a narrowly scoped `nonisolated(unsafe)` on the
  locally-built request array are the honest fixes; do not restructure the
  design around them.

---

## Deliverables

    macos/
      AINews.xcodeproj/                 // hand-written, synchronized folder groups
      AINews/
        AINewsApp.swift                 // @main, ModelContainer, scenes
        Info.plist                      // ATS exception for leiphone.com
        Models/
          Source.swift
          Headline.swift
        Services/
          TranslationCoordinator.swift  // on-device English translation
          AggregationEngine.swift
          FeedClient.swift
          FeedParser.swift
          SourceImporter.swift
        State/
          AggregatorStore.swift
        Views/
          SourceListView.swift
          HeadlineListView.swift
          ProgressBarView.swift
          SettingsView.swift
        Resources/
          sources.json
      AINewsTests/
        TranslationTests.swift
        FeedParserTests.swift           // one fixture per format: RSS 2.0, RDF, Atom
        CooldownTests.swift
        FailurePolicyTests.swift
      README.md

---

## Seed sources

30 entries in the exact editorial order, mirroring `Resources/sources.json`,
which ships in the app bundle and is what the importer reads.

| # | source_id | name | feed | expected format |
|---|---|---|---|---|
| 1 | `jiqizhixin` | Jiqizhixin (机器之心) | — | — |
| 2 | `qbitai` | QbitAI (量子位) | — | — |
| 3 | `aiera` | AI Era (新智元) | — | — |
| 4 | `zhidongxi` | Zhidongxi (智东西) | — | — |
| 5 | `leitech` | LeiTech (雷科技) | — | — |
| 6 | `leiphone` | Leiphone (雷锋网) | `http://www.leiphone.com/feed/` | RSS |
| 7 | `jiazi` | Jiazi Guangnian (甲子光年) | `https://werss.bestblogs.dev/feeds/MP_WXS_3599245772.atom` | Atom |
| 8 | `digitimes` | DIGITIMES | — | — |
| 9 | `etnews` | ETNews (Electronic Times) | `https://www.etnews.com/rss/` | RSS |
| 10 | `nikkei_xtech` | Nikkei xTECH (日経クロステック) | `https://xtech.nikkei.com/rss/index.rdf` | RDF |
| 11 | `ithome` | ITHome (IT之家) | `https://www.ithome.com/rss/` | RSS |
| 12 | `aiwatch` | AI Watch (Impress) | — | — |
| 13 | `technews_tw` | TechNews (科技新报) | `https://technews.tw/feed/` | RSS |
| 14 | `bnext` | Business Next (數位時代) | `https://www.bnext.com.tw/rss` | RSS |
| 15 | `ifanr` | ifanr (爱范儿) | `https://www.ifanr.com/feed` | RSS |
| 16 | `sspai` | sspai (少数派) | `https://sspai.com/feed` | RSS |
| 17 | `technode` | TechNode | — | — |
| 18 | `tnglobal` | TNGlobal | — | — |
| 19 | `techorange` | TechOrange (科技報橘) | `https://techorange.com/feed/` | RSS |
| 20 | `inside_tw` | INSIDE (硬塞的) | `https://www.inside.com.tw/feed` | RSS |
| 21 | `inc42` | Inc42 Media | `https://inc42.com/feed/` | RSS |
| 22 | `thenewslens` | The News Lens | — | — |
| 23 | `thebridge` | TheBridge | `https://thebridge.jp/feed` | RSS |
| 24 | `nikkei_asia` | Nikkei Asia | `https://asia.nikkei.com/rss/feed/nar` | RSS |
| 25 | `toyokeizai` | Toyo Keizai (東洋経済) | `https://toyokeizai.net/list/feed/rss` | RSS |
| 26 | `yonhap` | Yonhap News Agency (Tech) | `https://www.yna.co.kr/rss/news.xml` | RSS |
| 27 | `digitaltoday` | DigitalToday English | — | — |
| 28 | `nikkei_robotics` | Nikkei Robotics (日経Robotics) | — | — |
| 29 | `nikkei_tech_foresight` | NIKKEI Tech Foresight | — | — |
| 30 | `zdnet_korea` | ZDNet Korea | `https://zdnet.co.kr/rss/allArticle.xml` | RSS |

**17 sources have a feed and are fetchable in v1. 13 have none** and
must be skipped with `.noFeed` — visible in the UI as unsupported, **not**
silently hidden and **not** marked inactive.

Do not invent a 30th source. An earlier prompt asked for a placeholder to pad
the list to 30; that is obsolete. The list is complete at 30.

---

## Configuration that will silently break the app if missed

1. **ATS.** 1 seed feed is plain HTTP and App Transport Security
   refuses it unless excepted:
   - 雷锋网 (Leiphone) → `http://www.leiphone.com/feed/`

   Add a **narrow** `NSExceptionDomains` entry for `leiphone.com` in
   `Info.plist`. Do **not** use blanket `NSAllowsArbitraryLoads`. Under the
   exception the failure is silent and unhelpful, so verify this source
   specifically during testing.
2. **App Nap.** Wrap a run in
   `ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason:)`
   or macOS throttles the jitter sleeps and the run crawls. End the activity on
   both completion **and** cancellation.
3. **No sandbox entitlement is needed** — the app is deliberately unsandboxed.
   If you enable the sandbox anyway, outbound requests fail until
   `com.apple.security.network.client` is set.

---

## Implementation notes

1. **Strict concurrency is not optional.** Build in Swift 6 language mode.
   `SourceSnapshot` and `ParsedItem` are `Sendable` value types — pass
   snapshots into the actor, never `@Model` instances across isolation
   boundaries. SwiftData models are not `Sendable`.
2. **The engine imports no SwiftUI; the views do no I/O.** Everything the engine
   touches must be testable with no network.
3. **Dedup** uses `#Unique` on `Headline.url`. On conflict, update
   `lastSeenAt` rather than inserting a duplicate.
4. **Cooldown** is evaluated *before* any network work, against
   `lastAttemptedAt` (not `lastFetchedAt`) — a failed attempt still counts as
   an attempt, or a permanently broken source gets hammered on every run.
5. **Warn, do not deactivate.** v1 must **never** write `isInactive` — the
   only writer is the user. Every failure increments `consecutiveFailures`,
   records `lastWarning` / `lastWarningAt` and is surfaced in the UI, then the
   run moves on. The auto-deactivation thresholds in architecture.md §6 exist
   behind a setting that defaults to **off**; implement the setting, do not
   enable it.
6. **A 304 is a success.** If conditional requests are implemented, a 304 must
   reset the failure counter, not increment it.
7. **Logging** via `os.Logger`, subsystem `net.kuyawa.ainews`, one category per
   component. Format: `fetch source=ithome status=200 new=3 total=12`
8. **Never fetch an article URL.** Assert it in the client.
9. **Expect 13 skips.** Until scraping exists, every run reports 13
   `noFeed` skips. Make the reason visible in the UI so this is not mistaken
   for a bug.

---

## Testing checklist

Verify before declaring done:

- [ ] `xcodebuild -scheme AINews build` succeeds with **zero warnings** in Swift 6 mode
- [ ] App launches, creates the store, imports 30 sources ranked 1–30 in the given order
- [ ] Sidebar shows all 30 in AI-first order with RSS/SCRAPE badges
- [ ] A run skips exactly 13 sources with reason `noFeed` and fetches the other 17
- [ ] IT之家, 日経クロステック and 甲子光年 each parse successfully — one RSS 2.0, one RDF, one Atom
- [ ] 雷锋网 (plain-HTTP feed) succeeds, proving the ATS exception works
- [ ] Re-running immediately yields `cooldown` skips, not network requests
- [ ] Setting `isInactive = true` on a source removes it from runs and dims it in the sidebar
- [ ] A simulated 403 warns "blocked (HTTP 403)", increments the counter, and **leaves `isInactive` false**
- [ ] A feed truncated to zero items warns "empty feed" and does **not** deactivate
- [ ] `FetchRouter` returns `.feed` for a source with a feed, `.none` without, and `.scrape` when only a selector is set
- [ ] `AggregationEngine` compiles with a mock `SourceFetching` and imports no feed-specific type
- [ ] Headlines survive quit and relaunch
- [ ] Reload Sources re-imports without wiping failure counters or timestamps
- [ ] Clicking a headline opens the default browser to the real article
- [ ] A Chinese, Japanese and Korean source each show an English headline with the original beneath
- [ ] Translation runs during the pause between sources, not after the run
- [ ] Re-running translates nothing a second time
- [ ] The Originals toggle swaps to the publisher's own headline
- [ ] With translation off in Settings, no session is ever opened
- [ ] Stop cancels mid-run without marking the in-flight source as failed
- [ ] Parser tests pass via ⌘U against committed fixtures for all three formats

---

## Explicitly out of scope

- HTML scraping and per-source CSS selectors (§14 of architecture.md defers this)
- Article fetching, full-text extraction, summarisation
- Cloud translation services: translation is on-device only (see below)
- Scheduled or background fetching, launch at login, menu bar extra
- iOS / iPadOS targets
- Accounts, sync, analytics, telemetry
- App Store submission, notarisation, distribution signing
- The earlier browser-based version — superseded, not part of this repository
- Editing source configuration in-app beyond the enable/disable toggle

---

## Style guidelines

- Favour clarity over abstraction. This is a personal tool, not a framework.
- One type per file, named after the type.
- **No third-party dependencies.** If you believe one is needed, stop and say why
  before adding it.
- Comment the **why** for anything non-obvious — especially the cooldown
  condition, the failure thresholds, and the `auto:` reason prefix.
- Prefer `async/await` over completion handlers and timers throughout.
- Use system materials and colours so the app looks native in both appearances.
- Fixture files for parser tests belong in the test target, not in Resources.

---

## When done

Provide:

1. A one-paragraph summary of what was built.
2. The file tree as created.
3. **Proof the three feed formats parse** — the fixture used and the item count for
   RSS 2.0, RDF and Atom.
4. Confirmation that the 雷锋网 plain-HTTP feed actually loaded, and how you
   verified it.
5. Any deviation from architecture.md, with the reason.
6. The exact command to build and run.