# Better Streaming — work queue

Living backlog so work survives across sessions. Newest priorities at top of "Open".

## Open (priority order)

1. **Streaming playback (start before full download)** — TOP. Today `LibraryService.playableURL` downloads the whole file before play (cache-first), so 100MB+ FLAC albums take forever to start. Build range streaming: `AVAssetResourceLoaderDelegate` custom scheme serving AVPlayer byte-range requests via `SMBRemoteClient.read(path, range:)` (SMB supports ranges); content-info from `stat`; write fetched ranges into the on-disk cache as they arrive (progressive). WebDAV/HTTP: stream directly via `AVURLAsset` + `AVURLAssetHTTPHeaderFieldsKey` (Basic auth). Keep cache-first as fallback. Needs device testing (start latency, seek, formats).

2. **Auto-cache hardening** — (a) manual downloads must not be auto-evicted: add a pinned flag/state, exclude from `makePlan.evict`; (b) auto-cache keeps should be `.prefetched` not `.cached` (so Offline ▸ Auto-cached works); (c) budget never enforced because `durationSeconds=0` → use `track.sizeBytes` in `bytesEstimate`; (d) hide Download/Remove for local-source tracks; (e) wire SourcesView "Rescan" button → `model.rescan`; (f) onboarding re-present race → set `hasCompletedOnboarding` synchronously before the `await`.

3. **FTP adapter** — `FTPRemoteClient: RemoteFileSystemClient` via Network framework (control+data channels, PASV, LIST parse, SIZE/MDTM, RETR+REST). Wire Package.swift + `LibraryService.buildClient` + flip `SourceProtocol.ftp.hasAdapter`.

4. **SFTP adapter** — `SFTPRemoteClient` via an SPM SSH lib (Citadel or mft — vet that it builds on iOS). list/stat/read-range/download. Wire like FTP.

5. **MediaStore/GRDB persistence swap + dedupe Core types** — replace the JSON library snapshot with MediaStore (needs a bulk fetch-all API added to MediaStore first; better at 50k tracks/FTS). Dedupe duplicate Core types: `SourceModels` (Domain vs Sources), `CacheJobID`, `CacheRecord`, queue snapshots.

6. **Embedded artwork at scan for remote (SMB/WebDAV)** — covers currently pull at scan for local only (folder image or embedded) and on-play for remote. Pull a folder cover.jpg / first-track embedded art for remote albums too (small ranged read), without full download.

## Done (pushed to main)

- SMB scan robustness + surfaced errors; cache-size presets → clean GB
- Interactive remote folder picker (setup + onboarding)
- Local files as a source (Files/iCloud/on-device), excluded from auto-eviction
- Library Songs Play/Shuffle header; search auto-focus; search shows album blocks
- Album covers pulled at scan (folder image or embedded) for local
- Now Playing: timer fix, menu-pulse fix, swipe-down dismiss on artwork/title
- Shuffle starts on a random track; track-number titles stripped + albums ordered
- Playback path hardening; integrated crash + cold-launch fixes
