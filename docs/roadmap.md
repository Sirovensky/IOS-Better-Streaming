# Implementation Roadmap

Date: 2026-06-28

## Purpose

This is the build coordination plan for the next phase. Multiple builder agents should be able to work in parallel without redefining product scope, module boundaries, or the first vertical slice.

The product target is a music-first iPhone app for personal NAS and local-server media. Remote folders should behave like a real library: searchable, queueable, playable recursively, cacheable, and usable offline. Video is included, but the first proof point is reliable SMB music playback.

## Locked Decisions

- Build an iOS 17+ SwiftUI app first.
- Keep the app target thin. Core logic lives in `Packages/BetterStreamingCore`.
- Use XcodeGen and edit `project.yml`, not generated project files.
- Use Swift Concurrency and Swift 6 where dependencies allow.
- Use GRDB/SQLite for the media store. Do not use SwiftData/Core Data for the index.
- Use SMB as the first real protocol, through `SMBClient`.
- Keep `AMSMB2` as a fallback spike only until licensing and packaging are settled.
- Add WebDAV/HTTP second, after the media identity, scan, queue, cache, and playback model are stable.
- Use AVPlayer/AVQueuePlayer first.
- Start playback cache-first, then add loopback HTTP range streaming.
- Keep `AVAssetResourceLoader` as a fallback strategy, not the default streaming path.
- Add VLCKit only after the core app works and the license/package gate is complete.
- Store credentials in Keychain only.
- Do not persist raw remote URL strings as media identity.
- Do not log credentials, credential-bearing URLs, or unredacted diagnostic data.
- The first screen is Library, not a protocol picker.

## Quality Bar

The first credible beta must pass these checks:

- Add an SMB source and start music playback in under 2 minutes from a fresh install on a normal local share.
- Folder playback works before a deep recursive scan finishes.
- Recursive shuffle on a 5k-10k track folder starts before the full tree is scanned.
- Cached audio continues from the lock screen.
- Queue state survives app restart.
- Offline Mode never marks uncached remote-only media as playable while offline.
- Search stays responsive on a 50k-track library.
- A moved source or root folder can be repaired without manually rebuilding playlists.
- Diagnostics and logs strip credentials and sensitive tokens.

## First Vertical Slice

Build this before polishing broad UI or adding more protocols:

```text
Fresh install
-> add SMB source
-> choose root folder
-> path-first scan
-> browse Folders
-> tap Play Folder
-> cache first playable file
-> play with AVQueuePlayer
-> persist queue
-> relaunch and resume queue context
```

Acceptance criteria:

- Manual SMB source setup supports host, share, username, password, optional domain/workgroup, and connection test.
- Source credentials are written to Keychain and never stored in filenames, logs, SQLite, or diagnostics.
- Local Network permission copy is present and human-readable.
- Root folder selection supports Music, Video, and Mixed tags.
- Path-first scan persists folders and files as they are discovered.
- Folder rows distinguish unscanned, scanning, playable, cached, offline-missing, and failed states.
- Current-folder Play and Shuffle do not wait for subtree traversal.
- First playable file is downloaded to app cache and played through AVQueuePlayer.
- Audio session, Now Playing metadata, remote play/pause, and lock-screen continuation work on device.
- Queue restore works after app relaunch.

Explicitly excluded from this slice:

- Album and artist screens.
- M3U import/export.
- Durable offline-pack UI.
- WebDAV, FTP, SFTP, NFS, DLNA.
- Video playback.
- VLCKit.
- Custom equalizer, lyrics, CarPlay, Chromecast.
- Broad artwork polish.

## Dependency Order

Build order is strict until the first vertical slice is complete:

```text
Contracts
-> app shell and package layout
-> domain identity types
-> MediaStore schema
-> fake RemoteFileSystem
-> minimal Library/Folders UI
-> SMB source setup
-> path-first scanner
-> folder queue actions
-> cache-first AVPlayer playback
-> queue persistence
-> lock-screen/audio-session integration
```

After the vertical slice merges, work can branch into range streaming, offline packs, metadata/search, playlists, WebDAV, diagnostics, and video.

## Phase 0: Contracts and Spikes

Goal: prove the riskiest assumptions before UI polish.

Work:

- Finalize `docs/internal-contracts.md`.
- Spike SMB list, stat, byte-range read, and full-file download.
- Spike 10k-file recursive traversal with cancellation and bounded memory.
- Spike AVPlayer playback from a cached SMB-downloaded file.
- Verify lock-screen audio and remote commands on a physical device.
- Spike loopback HTTP range proxy for at least MP3, M4A, FLAC, and MP4 seek behavior.
- Run GRDB/FTS insert/query tests with 50k tracks and folders.

Acceptance:

- A real or fixture-backed SMB client can read exact byte ranges.
- A scan can resume from checkpoints after cancellation or process restart.
- Cached audio keeps playing after device lock.
- Loopback proxy supports `HEAD`, `GET`, `Range`, `206`, `416`, cancellation, and redacted logs.
- FTS path/title queries remain responsive with seeded large-library data.

Do not build polished album grids, playlist editors, or custom player chrome in this phase.

## Phase 1: Project Shell and Foundations

Goal: create a runnable app and testable package structure.

Work:

- Add `project.yml` and generate `BetterStreaming.xcodeproj`.
- Create SwiftUI app target under `App/BetterStreaming`.
- Create `Packages/BetterStreamingCore` with module targets from `docs/build-structure.md`.
- Add app entitlements and Info.plist purpose strings for Local Network and background audio.
- Add SwiftFormat config and scripts for project generation, build, tests, and formatting.
- Define domain identity and state types.
- Add GRDB and the first schema migrations.
- Add in-memory/fake filesystem fixtures for UI and scanner development.

Acceptance:

- `xcodegen generate` works.
- App builds and launches to a Library shell.
- `swift test --package-path Packages/BetterStreamingCore` runs.
- Domain tests cover identity normalization and equality.
- Store tests run migrations on an empty database.

## Phase 2: Sources, RemoteFileSystem, and Diagnostics Base

Goal: add and test an SMB source.

Work:

- Implement `RemoteFileSystemClient` contract and fake client tests.
- Implement `SMBRemote` adapter around `SMBClient`.
- Implement `BetterStreamingSources` source records, credential references, and Keychain wrapper.
- Add manual SMB setup flow with connection test and root listing.
- Map connection failures to human categories: server asleep, auth failed, local network blocked, share missing, timeout, unsupported.
- Add basic speed test and source-health snapshot.

Acceptance:

- Manual SMB source can be saved, tested, and reopened.
- Credentials round-trip through Keychain only.
- Root folders can be listed after source setup.
- Errors are redacted and stable enough for UI copy.
- Real SMB integration tests are opt-in and do not require checked-in secrets.

## Phase 3: Path Library and Folder Surface

Goal: make remote folders browsable and playable before metadata exists.

Work:

- Implement path-first recursive scanner.
- Persist scan checkpoints per source and subtree.
- Add cancellation, pause/resume, and subtree scans.
- Persist folders, media files, basic type hints, size, modified time, natural sort keys, and path FTS.
- Build Folders UI against `MediaStore`.
- Add folder status: unscanned, scanning, partial, complete, offline, failed.

Acceptance:

- Scanning a large tree keeps memory bounded.
- The UI updates progressively as folders/files are found.
- Current-folder Play and Shuffle become available as soon as current-folder playable files exist.
- Recursive actions show progressive count while traversal continues.
- Restarting the app resumes or clearly restarts an interrupted scan without duplicate rows.

## Phase 4: Queue and Cache-First Playback

Goal: play music reliably through AVPlayer from local cache.

Work:

- Implement queue model: play, shuffle, play next, append, reorder, clear.
- Persist queue and current item context.
- Implement complete-file cache records and app-storage paths.
- Download current track to cache.
- Set file protection so active cached media remains readable after first unlock.
- Implement AVQueuePlayer audio renderer.
- Add audio session, interruptions, route changes, Now Playing metadata, and remote commands.
- Add mini player and Now Playing states with real playback data.

Acceptance:

- Folder Play starts by caching and playing the first track.
- Queue survives app relaunch.
- Lock-screen play/pause works on a physical device.
- Interruption and route-change behavior is handled without corrupting queue state.
- Cache failures produce retryable, user-readable states.

## Phase 5: Range Streaming and Prefetch

Goal: start uncached files quickly without giving renderers remote credentials.

Work:

- Finalize loopback HTTP range proxy in `StreamBridge`.
- Use tokenized loopback URLs bound to `127.0.0.1` and `::1`.
- Serve cached chunks before remote reads.
- Implement playback byte cache records.
- Add prefetch for current item plus next 1-3 audio queue items.
- Keep complete-cache fallback for every streaming failure.

Acceptance:

- AVPlayer can start common audio files through loopback URLs.
- Seeking works near start, middle, and end.
- Remote read cancellation happens when playback seeks or stops.
- Proxy logs and URLs contain no credentials.
- Slow reads produce buffering or pre-cache recommendations, not silent failure.

## Phase 6: Offline Cache and Downloads

Goal: make offline confidence visible and correct.

Work:

- Add durable pins for files, folders, recursive folders, and playlists.
- Add Downloads tab with active transfers, failures, storage budget, and retry.
- Add Offline Mode and Playable Only filters.
- Add quota, eviction, partial-file recovery, stale detection, and verification.
- Distinguish manual downloads, folder pins, playlist pins, smart packs, and queue prefetch.

Acceptance:

- Offline Mode keeps library context but never presents uncached remote-only media as playable.
- Pinned files survive normal eviction.
- Partial downloads resume or restart cleanly.
- Quota policy is deterministic and tested.
- UI shows cached, downloading, queued, prefetched, stale, remote-only, missing-source, and failed states with icon plus label.

## Phase 7: Metadata, Artwork, and Search

Goal: turn path data into a real music library without blocking folder use.

Work:

- Add throttled metadata extraction behind path-first scan.
- Extract duration, artist, album, title, track, disc, and embedded artwork where cheap.
- Add folder artwork lookup for `cover.jpg`, `folder.jpg`, and similar files.
- Add artwork thumbnail cache.
- Backfill FTS for title, artist, album, filename, and path.
- Add Songs, Albums, Artists, and global Search.

Acceptance:

- Folder playback never waits for tag extraction.
- Search remains responsive on 50k seeded tracks.
- Missing artwork has generated warm graphite placeholders.
- Album/artist screens degrade cleanly for untagged or partially tagged libraries.

## Phase 8: Playlists

Goal: support durable playlists without confusing them with transient queues.

Work:

- Add app playlists containing media items, folder references, and live recursive folder references.
- Add playlist editing, reorder, remove, duplicate handling, and queue conversion.
- Add offline pinning intent for playlists.
- Add M3U import/export after playlist identity is stable.
- Add repair warnings for unresolved imported paths.

Acceptance:

- Playlists can contain remote-only items without downloading them.
- Live folder playlists update from the library model.
- Pinning a playlist schedules cache work without changing queue order.
- Imported M3U paths either resolve to stable items or show repair warnings.

## Phase 9: WebDAV/HTTP

Goal: add the second protocol without changing the app model.

Work:

- Add `WebDAVRemote` behind `RemoteFileSystemClient`.
- Reuse source setup, scan, queue, cache, playback, offline, and diagnostics flows.
- Use `URLSession` background downloads where possible.
- Preserve the same media identity and repair behavior.

Acceptance:

- WebDAV sources pass the same RemoteFileSystem contract tests as SMB.
- HTTP range support is detected and used.
- Background download behavior is honest in UI copy.
- No UI flow forks into a protocol-specific file manager.

## Phase 10: Video and Compatibility

Goal: add video while keeping music-first behavior stable.

Work:

- Add video classification and Video library surface.
- Use AVPlayer/AVKit for MP4, M4V, MOV, and device-supported files.
- Add resume position, PiP where supported, AirPlay where supported, and HDR probing.
- Discover sidecar subtitles during scan.
- Add basic SRT/WebVTT overlay only if usage justifies it before VLCKit.
- Complete VLCKit license/package gate before adding compatibility mode.
- Add VLCKit behind a renderer abstraction and feature flag.

Acceptance:

- AVPlayer video does not regress audio queue behavior.
- Unsupported files remain visible with clear reasons.
- VLCKit is not shipped until LGPL/module audit, attribution, source availability, archive validation, and TestFlight device testing are complete.

## Phase 11: Repair, Diagnostics, and Beta Hardening

Goal: make real NAS failures understandable and recoverable.

Work:

- Add source and root-folder repair flows.
- Add speed tests and stream/pre-cache recommendations.
- Add source capability snapshots.
- Add redacted debug bundle export.
- Add NAS compatibility notes and bug-report templates.
- Build real-device manual test checklist.

Acceptance:

- Renamed/moved roots can be remapped by user confirmation.
- Diagnostics export is redacted by tests.
- Failure states map to human copy first and technical details second.
- Beta checklist covers Synology, QNAP, TrueNAS, Windows share, macOS sharing, slow Wi-Fi, VPN, and Local Network permission denial.

## Parallel Workstreams

Before the first vertical slice, parallelism is limited:

| Workstream | Owns | Can start when | Must coordinate |
| --- | --- | --- | --- |
| App shell | `project.yml`, app target, package scaffolding | Immediately | Module names and schemes |
| Domain/store | `BetterStreamingDomain`, `MediaStore` | Immediately | Migration numbers |
| Fake filesystem/UI | fake `RemoteFileSystem`, Library/Folders UI | Domain sketches exist | Row state names |
| SMB/source | `SMBRemote`, `BetterStreamingSources` | RFS and Source contracts exist | Error taxonomy |
| Playback/cache | `CacheManager`, `PlaybackCore` | Media identity exists | Queue item identity |
| Diagnostics | `Diagnostics` base | RFS errors exist | Redaction helper |

After the first vertical slice:

| Workstream | Owns paths | Can run after | Must not touch |
| --- | --- | --- | --- |
| WebDAV source | `RemoteFileSystem`, `WebDAVRemote`, source setup additions | RFS contract stable | Queue policy, SMB internals |
| Metadata/artwork | `MetadataCore`, media migrations, album/artist UI | Path scanner and store schema exist | Source credential storage |
| Offline packs | `CacheManager`, Downloads UI, quota settings | Cache-first playback works | Metadata extraction internals |
| Playlists/M3U | `PlaylistCore`, Playlists UI, playlist migrations | Queue item identity is stable | Player renderer internals |
| Range streaming | `StreamBridge`, byte cache, playback resolver | Proxy decision is made | Source setup UI |
| Video playback | Video UI, renderer abstraction, optional `VLCKitBridge` | Audio queue/cache stable | Credential handling |
| Diagnostics | Health UI, speed tests, export bundle | Source setup and RFS errors exist | Renderer internals except errors |
| Performance harness | `Tools/scripts`, fixtures, large-library tests | Store and scanner exist | Product UI layout |

Schema rule: one agent owns migration numbers at a time. If two workstreams need migrations, one waits for the merged schema or coordinates explicitly.

## What Not To Build Yet

Do not build these before the first vertical slice:

- Protocol breadth: WebDAV, FTP, SFTP, NFS, DLNA, cloud drives.
- Platform breadth: iOS 16, iOS 15, tvOS, macOS, CarPlay, Chromecast.
- Codec breadth: VLCKit, FFmpeg, mpv, GStreamer, custom decoders.
- Full video player polish.
- Album/artist-first library experience.
- M3U import/export.
- Lyrics, tag editor, equalizer, social sharing, Last.fm.
- Background auto-sync of all sources.
- Plex, Jellyfin, Navidrome, or server-component integrations.
- Marketing-first landing screens inside the app.
- A generic file manager or first-run protocol picker.
- Donation gates around core source setup, SMB playback, recursive folders, queue, playlists, offline playback, privacy controls, or security fixes.

## Builder Rules

- Keep every change runnable.
- Add or update tests in the module you touch.
- Keep UI out of service modules.
- Keep service dependencies out of domain types.
- Do not edit generated Xcode project files by hand.
- Do not add a third-party dependency without documenting the decision.
- Do not persist raw remote URLs as identity.
- Do not log credentials or credential-bearing URLs.
- Use semantic UI state from the contracts instead of inventing one-off row states.
- Make source, scan, cache, queue, playback, and diagnostics errors redaction-safe by default.
- If a feature needs a schema change, own the migration and development reset story.

## Required Local Commands

Once the app shell exists, these commands should remain valid:

```sh
xcodegen generate
xcodebuild -project BetterStreaming.xcodeproj -scheme BetterStreaming -destination 'platform=iOS Simulator,name=iPhone 16' build
swift test --package-path Packages/BetterStreamingCore
```

Real-device testing is mandatory for Local Network permission, Keychain behavior, lock-screen controls, audio session interruptions, route changes, and app suspension.
