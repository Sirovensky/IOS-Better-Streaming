# Better Streaming — work queue

Living backlog so work survives across sessions. Newest priorities at top of "Open".

## Open (priority order)

1. **PARTIAL — Streaming playback (start before full download)** — Range-streaming path is implemented for remote files through `AVAssetResourceLoaderDelegate` + `RemoteFileSystemClient.read(path, range:)`, with content-info from `stat`, bounded chunk reads, cancel handling, progressive range cache, and full-download fallback for non-range files/adapters. Verified by simulator, unsigned iPhoneOS builds, signed install to a physical iPhone 17 Pro, and audible NAS MP3 playback. FLAC started audibly but stalled after ~9 seconds before the latest larger range-response cap; needs retest. M4A and video still need real-device NAS playback testing. Permanent stale-library fix added: persisted tracks whose source config is missing are dropped, and unplayable tracks now show a visible mini-player error instead of endless loading.

2. **DONE — Embedded-tag metadata during scan (fix "Music" artist)** — scan now reads embedded tags from local files and remote ranged probes (ID3, FLAC/Vorbis comments, MP4/iTunes atoms, Ogg/Opus tags), merges title/artist/album/genre/track/disc values into tracks, falls back to path metadata only when tags are absent, and prevents the scan-root folder from becoming the artist.

3. **DONE — Radio tab (local-library stations)** — Apple-Music-style Radio over the user's own library. New tab between **Home and Library** (order: Home, Radio, Library, Search). Auto-generates stations from real metadata: library shuffle, artist stations, genre stations, and "similar to <seed>" stations. Station playback uses large shuffled queues (`engine.playShuffled`).

3. **Pre-cache next queue track (when online)** — when network is reachable, prefetch the next track in the play queue ahead of time so playback is gapless and instant on advance. Trigger on track-start (or when current track passes ~halfway), fetch next track's bytes into the on-disk cache (or warm the streaming range cache once #1 lands). Only when reachable (skip on cellular if a "Wi-Fi only" setting is on); cancel/replace prefetch when the queue changes or user skips. Tie into auto-cache budget so prefetch doesn't evict pinned/favorites. After #1 (streaming) this becomes "prime the next track's resource-loader range cache."

3. **DONE — Auto-cache hardening** — (a) manual downloads must not be auto-evicted: add a pinned flag/state, exclude from `makePlan.evict`; (b) auto-cache keeps should be `.prefetched` not `.cached` (so Offline ▸ Auto-cached works); (c) budget never enforced because `durationSeconds=0` → use `track.sizeBytes` in `bytesEstimate`; (d) hide Download/Remove for local-source tracks; (e) wire SourcesView "Rescan" button → `model.rescan`; (f) onboarding re-present race → set `hasCompletedOnboarding` synchronously before the `await`.

3. **DONE — FTP adapter** — `FTPRemoteClient: RemoteFileSystemClient` via Network framework: control+data channels, EPSV/PASV, LIST parser, SIZE/MDTM stat, RETR+REST range reads, full downloads, Package.swift wiring, `LibraryService.buildClient`, and `SourceProtocol.ftp.hasAdapter`.

4. **DONE — SFTP adapter** — `SFTPRemoteClient` via Citadel: list/stat/read-range/download, Package.swift wiring, `LibraryService.buildClient`, and `SourceProtocol.sftp.hasAdapter`. Verified with package tests, simulator build, and unsigned iPhoneOS build. Signed install still requires adding an Apple development team/provisioning profile for `com.betterstreaming.app`; the current project has no team set.

5. **DONE — MediaStore/GRDB persistence swap + dedupe Core types** — library reads/writes through MediaStore with bulk list/replace/delete APIs, legacy JSON migration fallback, and deduped Core types for `SourceModels`, `CacheJobID`, `CacheRecord`, and queue snapshots. Verified with package tests and simulator app build.

6. **DONE — Embedded artwork at scan for remote (SMB/WebDAV)** — remote scan now prefers folder cover files and otherwise caches first embedded album art from ranged metadata probes, without downloading full media files. Embedded art parsing covers ID3 APIC/PIC, FLAC picture blocks, Vorbis/Opus picture comments, and MP4 `covr`. Verified with package parser tests, simulator app build, and unsigned iPhoneOS build.

## Done

- SMB scan robustness + surfaced errors; cache-size presets → clean GB
- Interactive remote folder picker (setup + onboarding)
- Local files as a source (Files/iCloud/on-device), excluded from auto-eviction
- Library Songs Play/Shuffle header; search auto-focus; search shows album blocks
- Album covers pulled at scan (folder image or embedded) for local
- Now Playing: timer fix, menu-pulse fix, swipe-down dismiss on artwork/title
- Shuffle starts on a random track; track-number titles stripped + albums ordered
- Playback path hardening; integrated crash + cold-launch fixes
- Auto-cache hardening: manual downloads protected, auto-cache uses `.prefetched`, size budgets use file size, local download controls hidden, Sources Rescan wired, onboarding race fixed
- Embedded metadata scanning: local + remote ranged tag probes for title/artist/album/genre/track/disc, with scan-root artist fallback fixed
- Radio tab: library, artist, genre, and similar stations generated from the user's scanned library
- FTP adapter: Network.framework FTP client with passive list/stat/range-read/download support wired into source setup
- SFTP adapter: Citadel-backed SSH/SFTP client with list/stat/range-read/download support wired into source setup
- Remote artwork scan: folder covers plus embedded ID3/FLAC/Vorbis/MP4 artwork cached during remote scans
