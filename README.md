# Tsundoku

Tsundoku is a native Swift 6/SwiftUI reader for iPhone and iPad. It targets iOS/iPadOS 26+, Komga 1.25+, and Kavita 0.9.0.2+.

The app is personal/internal TestFlight software. Komga and Kavita are first-class content providers; no third-party source extensions are used.

## Current implementation

- Multiple mixed Komga and Kavita profiles with server-scoped identifiers and synchronizable Keychain credentials.
- Provider-neutral libraries, series, collections, reading lists, search, recent updates, covers, chapter adjacency, downloads, and progress synchronization.
- HTTPS enforcement with a narrow exception for private, link-local, loopback, `.local`, and unqualified LAN HTTP hosts.
- Offline catalog fallback that remains visible while a server refresh is in progress or unavailable.
- Cloud-synced series pins shown first on Home, with consistent poster/title rails for pinned, in-progress, and recently updated series.
- Archive/image and server-rendered PDF reading through the existing UIKit collection reader:
  - right-to-left and left-to-right paging;
  - vertical continuous reading;
  - automatic/single/double spreads and cover-alone handling;
  - direction-aware wide-page splitting;
  - automatic border crop;
  - pinch and double-tap zoom;
  - brightness, page slider, bookmarks, keyboard navigation, prefetch, and bounded caches.
- Kavita EPUB reading through an ephemeral `WKWebView`:
  - paginated-column and continuous-scrolling modes;
  - table of contents, precise XPath resume, bookmarks, and cross-book navigation;
  - persistent theme, font, type size, line height, and margin settings;
  - script removal, restrictive content security policy, same-origin authenticated resources, and explicit external-link handling.
- Timestamp-aware progress with durable retries, deliberate rewind support, silent debounced in-reader writes, final-exit sync feedback, and explicit Mark Read/Mark Unread feedback.
- Background packages for image/PDF pages and Kavita EPUB spine/resource content, with pause/resume, protected files, and iCloud-backup exclusion.
- AniList implicit OAuth and MyAnimeList PKCE scaffolding, tracker search/link UI, configurable progress formulas, and queued updates only after the active content server acknowledges progress.
- Split SwiftData storage: CloudKit-backed user metadata and device-local catalogs, downloads, and pending mutations.

## Provider setup

### Komga

- Komga 1.25+ and the `PAGE_STREAMING` role are required.
- Enter an existing API key, or use email/password once so Tsundoku can create a device-specific API key. The password is discarded.
- Komga progress is normalized to one-based positions inside the app. Explicit rewinds use Mark Unread followed by a page write when needed.

### Kavita

- Kavita 0.9.0.2+ is required.
- Create an Auth Key in Kavita user settings and enter it with the server base URL.
- A full Kavita OPDS URL may be pasted as a convenience; Tsundoku extracts the base URL and Auth Key, then uses Kavita's richer REST API rather than OPDS.
- EPUB locator progress interoperates with Kavita through `bookScrollId`.
- Whole-volume archives use Kavita's enclosing volume name, number, and order instead of its synthetic `-100000` chapter marker.

Secrets are held in Keychain and are never stored in SwiftData, download manifests, cached HTML, or logs. Public servers must use trusted HTTPS. Local HTTP is accepted, but exposes credentials and reading activity to the LAN.

## Local configuration

1. Install XcodeGen if needed: `brew install xcodegen`.
2. Copy `Config/Personal.xcconfig.example` to `Config/Personal.xcconfig`.
3. Fill in the Apple development team, unique bundle identifier, and optional tracker client IDs.
4. Configure tracker callbacks as `tsundoku://oauth/anilist` and `tsundoku://oauth/mal`. The legacy callback scheme is intentionally retained for installed-app compatibility.
5. Run `xcodegen generate` and open `Tsundoku.xcodeproj`.
6. Select a personal team. Xcode should create the private CloudKit container `iCloud.<your bundle identifier>`.

The project, product, scheme, module, and source tree use the Tsundoku name. Configure your own unique bundle identifier, CloudKit container, application-group identifier, background-task identifiers, and OAuth callback scheme before shipping a build.

## Build and verification

```sh
xcodegen generate
xcodebuild test -quiet \
  -project Tsundoku.xcodeproj \
  -scheme Tsundoku \
  -destination 'platform=iOS Simulator,name=<your simulator>' \
  -only-testing:TsundokuTests \
  CODE_SIGNING_ALLOWED=NO
```

The credential-gated live Kavita test also accepts `KAVITA_LIVE_URL` and `KAVITA_LIVE_AUTH_KEY` as build settings. It restores the selected book's original read state even when an assertion fails.

Coverage includes legacy-provider migration, Komga DTOs and progress behavior, Kavita version/auth/header/filter/pagination/error policies, archive/PDF request construction, list mapping, forward/backward/complete EPUB progress, sanitization and credential removal, offline manifest completeness, reader page/tap/preload math, navigation, and tracker formulas.

## Known validation gaps

- Live Kavita validation depends on the formats present in the supplied account. Image/archive and PDF paths have deterministic request/DTO coverage when those formats are absent from the live server.
- Physical-device background relaunch, force-quit behavior, long offline sessions, and interrupted EPUB-resource downloads still need extended field testing.
- Live AniList/MAL token expiry and end-to-end tracker synchronization remain deferred.
- Continue profiling very large image books for memory growth and stale image requests.

`project.yml` is the source of truth; the generated `Tsundoku.xcodeproj` is checked in for convenience.
