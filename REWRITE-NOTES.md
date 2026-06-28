# Better Streaming — rewrite notes

Date: 2026-06-28

The app was rewritten from a mock-data UI shell into a real NAS/server music
player: an `AVPlayer` engine, a real SMB + WebDAV scan→cache→play pipeline, and
an Apple-Music-quality UI. No demo/sample content — the library populates only
from the user's own sources.

> Built without a Swift toolchain on this machine (it targets iOS 17 / macOS 14,
> builds on a Mac). Everything was written and statically cross-checked (a
> dedicated audit agent read every App file); expect to be the build/test loop
> for any residual compile fixes. Highest-risk spots to eyeball first are called
> out under "Verify on Mac".

## Architecture

```
SwiftUI views ─▶ AppModel (@Observable, @MainActor)
                   ├─ PlaybackEngine      AVPlayer, audio session, lock screen, queue
                   ├─ AutoCacheController  recency+frequency budget + eviction
                   └─ LibraryService (actor)  ── bridges Core ──▶
                        BetterStreamingSources  Keychain + SMB connection test
                        SMBRemote / WebDAVRemote  RemoteFileSystemClient
                        LibraryIndexer            recursive path-first scan
                      + KeychainStore (Security)  source passwords
                      + on-disk media cache (Caches/Media), JSON library snapshot
```

App target files (`App/BetterStreaming`):
- `Model/MediaModels.swift` — Track/Album/Artist/Playlist/LibrarySource/CacheState/SourceProtocol.
- `Services/PlaybackEngine.swift` — real AVPlayer transport, queue/shuffle/repeat/seek, AVAudioSession, MPNowPlayingInfoCenter, MPRemoteCommandCenter, interruptions.
- `Services/LibraryService.swift` — the Core bridge (scan, cache-first download, eviction, artwork).
- `Services/AutoCacheController.swift` — auto-cache policy (ask #7).
- `Services/KeychainStore.swift` — source password storage.
- `Services/Artwork.swift` — warm placeholder art (SwiftUI + lock-screen UIImage).
- `AppModel.swift` — root state, wiring.
- `Features/…` — Home, Library (+ detail/offline), Player (mini + Now Playing + queue), Search, Settings, Onboarding, Sources.

## Real end-to-end flow

1. First launch → `OnboardingView`: welcome → connect (protocol picker) → key settings.
2. `addSource` → password to Keychain, config persisted, **background recursive scan**
   (`RemoteLibraryScanner` over the SMB/WebDAV client) → `Track`s appear; artist/album
   derived from the NAS path (`…/Artist/Album/track.ext`).
3. Tap a track → resolver downloads it **cache-first** to `Caches/Media` (file extension
   preserved so AVPlayer decodes FLAC/ALAC/MP3/WAV/AIFF), then plays via AVPlayer with
   full lock-screen / Control Center / remote-command support.
4. Auto-cache: on every play, recency+frequency stats update; the controller keeps the
   hottest set within the byte budget and evicts coldest-first — favourites/downloads
   never auto-evicted (ask #7). Offline Mode plays only cached/ready tracks.

## Protocols

| Protocol | Status | Notes |
| --- | --- | --- |
| SMB | full | live pre-save connection test + scan + playback |
| WebDAV | full | `WebDAVRemoteClient` (PROPFIND list, ranged GET, streamed download); connects on add/scan |
| FTP | soon | needs a full NWConnection FTP implementation (control+data, PASV, LIST parse) |
| SFTP | soon | needs an SSH dependency (e.g. Citadel/mft) — pick + vet on Mac |

The app stays protocol-neutral: a new protocol = one `RemoteFileSystemClient` conformer +
one branch in `LibraryService.makeClient`. `SourceProtocol.hasAdapter` gates the UI
("soon" badge); `hasConnectionTest` gates the live test (SMB only today).

## Ask-by-ask

1. Slow launch — deferred per you (profile on Mac); demo gone + lighter model layer helps.
2. Home — rethought ("Listening Room": hero, Recently Played, **Heavy Rotation** from real play counts, Made For You, Recently Added, quiet source line).
3. Offline moved Settings → Library ▸ Offline.
4. SMB toolbar buttons removed from Library.
5. Library = Apple-Music category list + Recently Added.
6. AI artifacts — removed dead stub modules (StreamBridge/MetadataCore/PlaylistCore) + mock AppEnvironment + dead views; Core bug fixes applied (below).
7. Auto-cache + max storage — built (policy + Settings + onboarding + real download/evict).
8. Now Playing — Apple-Music/Spotify-quality full player + mounted mini player + queue.
9. (your follow-ups) FLAC/MP3 native; multi-protocol; first-run onboarding; open-source/multi-user (no demo).

## Core fixes applied (ask #6)

- `CacheManager.enforceQuota()` — real recency+budget eviction; added `maxAutoCacheBytes`, `setMaxAutoCacheBytes`, `notePlayed` (all additive).
- `PlaybackController.play()` — no longer reports `.playing` with zero renderers; throws `.sourceUnavailable` + emits failure.
- `Redactor` — all ~13 regexes hoisted to compile-once statics (logging hot path).
- Removed dead stub modules + their Package.swift entries.

## Deferred (with rationale)

- **MediaStore/GRDB persistence** — `LibraryService` uses a JSON snapshot + on-disk cache,
  which is correct and fast for normal libraries. Swapping to GRDB (better at 50k tracks,
  FTS search) is blocked by a real gap: `MediaStore` has no bulk "fetch all items" API, so
  whole-library load needs new store methods. Focused follow-up.
- **Duplicate-type dedupe** — `SourceModels` exists in both `BetterStreamingDomain` and
  `BetterStreamingSources`; `CacheJobID`/`CacheRecord` duplicated. Both halves are in use by
  different modules, so dedupe is a careful refactor (no longer affects the app, which keeps
  Core imports isolated to `LibraryService`).
- **FTP/SFTP adapters** — see protocol table.
- **Embedded-tag metadata** — track titles/artists are path-derived; per-file artwork is read
  from the cached file. Full tag extraction (ID3/Vorbis) for title/artist/album is a throttled
  background pass once a file is local.

## Verify on Mac (highest-risk, blind-written)

- `LibraryService` ↔ Core API calls (SMB client construction, `RemoteLibraryScanner.scan`,
  identity/path mapping).
- `WebDAVRemoteClient` PROPFIND XML parsing + range/HEAD behaviour against your server.
- Swift 6 strict-concurrency edges in `PlaybackEngine` (KVO/remote-command/notification closures).
- Mini-player bottom offset (`RootTabView`, `.padding(.bottom, 50)`) vs the real tab bar height.

## Build

```sh
xcodegen generate
xcodebuild -project BetterStreaming.xcodeproj -scheme BetterStreaming \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
swift test --package-path Packages/BetterStreamingCore
```

Swift 6 language mode. `Info.plist` declares background audio + Local Network + Bonjour.
New source files are auto-included (the target globs `App/BetterStreaming`). Real-device
testing required for Local Network permission, Keychain, lock-screen audio, interruptions,
and route changes.
```
