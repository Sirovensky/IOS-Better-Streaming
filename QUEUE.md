# Better Streaming — work queue & handoff

Self-hosted NAS/server music app (iOS 17 SwiftUI + SwiftPM `BetterStreamingCore`).
Goal: Apple-Music/Spotify-quality player over the user's own SMB/WebDAV/FTP/SFTP/local library. Open-source, multi-user, no demo data.

## Handoff context (read first)

- **No Swift toolchain on the dev (Linux) box.** All Swift is written + statically reviewed blind; the user builds/tests on a Mac (`xcodegen generate` then build). The device is an iPhone 17 Pro. You are NOT the build loop — make changes the user can build, and lean on static review.
- **Real test server available:** host `selfhosted-venus-series`, SMB shares **Swimming** and **Music** (Swimming needs username/password). Use it to verify folder structure, embedded-art presence/size, and metadata grouping. (Creds aren't in the repo — ask the user, or have them run an `smbclient`/`ls` dump.)
- **Two agents share this file** (this one + a "Codex" agent on another PC). `git pull --rebase origin main` before every push.
- **Commits:** author `Pavel <sirovensky@gmail.com>`, **no AI mentions/trailers**.
- **Supply chain:** `swift-nio-ssh` resolves to a fork `github.com/Wellz26/swift-nio-ssh` (Citadel 0.12.1 points there; we now declare it directly for the SFTP host-key fix). Audit/replace when possible.

## ACTIVE BUGS (priority order)

### 1. Streaming still stalls / caching issue (NOT fully fixed) — TOP
User reports streaming still stalls on **some** songs and on **scrub**, after the fixes below. This is the #1 issue.

**Symptoms observed:**
- Some songs play a few seconds (~4s) then stall into silence; others play fine. No clear pattern yet.
- On scrub: keeps playing the already-cached region, then after a few seconds the progress bar jumps to the target and EITHER resumes (if the data loads) OR sits in silence (stalled).
- Scrubbing to a position only works once playback has downloaded that far (cached) — live ranged reads at un-downloaded offsets are the failure point.

**What's already been done (commits `8e6f287`, `0adcbc3`):**
- Removed the 12MB `finishLoading()` cap that faked EOF (the original "plays ~9s then stops").
- Content-information request now finishes on its own WITHOUT serving its dataRequest, to push AVPlayer into byte-range/random-access mode (so it issues bounded ranged + seek requests). `App/BetterStreaming/Services/RemoteStreamingService.swift`.
- Per-chunk file writes (no shared long-lived `FileHandle`) to avoid corruption under AVPlayer's concurrent loading requests.
- Fully-streamed tracks are promoted into the media cache; bounded session map; stale partials reclaimed on launch.

**Leading hypotheses NOT yet resolved (start here):**
- **SMB transport can't serve concurrent / fast ranged reads.** `SMBRemoteClient.read` opens a NEW `fileReader` per call (open→read→close) — many round-trips, and two in-flight reads (playback + seek) may serialize or hang. `download()` reuses ONE reader and works, which supports this theory.
- **`didCancel` is unreliable on device** (documented). If AVPlayer issues `requestsAllDataToEndOfResource` for the first DATA request, our loop serves 0→EOF and, if not cancelled, hogs the SMB transport, so a concurrent seek read can't get through → "few-second delay then maybe stall".
- Need to confirm via device logs whether AVPlayer actually switched to BOUNDED ranged requests after the content-info fix (look for `BETTERSTREAMING_STREAM request ... allToEnd=` lines).

**Suggested next steps:**
1. Get device console logs (filter `BETTERSTREAMING_`): confirm request shape (bounded vs allToEnd), offsets, and where reads hang/error.
2. If still all-to-end / hogging: add a "latest data-request wins" epoch in `RemoteStreamSession` so an older serving loop aborts when a newer DATA request arrives (frees the SMB transport for seeks). Risk: AVPlayer prefetch concurrency — guard carefully.
3. Serialize SMB reads per session and/or reuse a single open `fileReader` for sequential reads (mirror `download()`), opening a fresh one only for seeks.
4. Consider `player.automaticallyWaitsToMinimizeStalling` and `currentItem.preferredForwardBufferDuration` tuning.
5. Bigger option: `AVQueuePlayer` + true progressive buffering, or a battle-tested approach (study VIMediaCache / KTVHTTPCache patterns — research notes are in the session).
6. Test matrix: MP3 vs FLAC vs M4A (M4A may also hit moov-atom-at-end → needs whole-file before play; detect moov position).

### 2. Album artwork missing for SMB (fix pushed — VERIFY on device)
- Just fixed (`66e26ef`): hi-res FLAC embedded covers (PICTURE block > 256KB probe) were never read because `parseFLAC` broke at the truncated block. Now the PICTURE block range is located from its header and ranged-read exactly; bounded fallback for ID3 APIC / MP4 covr. Art fetched once per album during scan. **Rescan required** to populate.
- If art is STILL missing after rescan: (a) check folder-cover detection — `Self.isFolderCover` names list (`LibraryService` ~line 438) vs what the server actually has (use the real server); (b) verify `artworkURL` survives the MediaStore round-trip — `track(fromMediaItem:)` / `mediaItem(from:)` must persist+restore `artworkURL`; (c) confirm the cached art file path is still valid after relaunch (Caches dir).
- Reference: VLC fetches Avantasia covers fine, so the art exists (embedded and/or folder cover).

### 3. Radio "similar to <seed>" picks unrelated genre
- Seed "Get Up (Original Mix)" Skrillex & Korn (dubstep) → first track played was an acoustic singer-songwriter (Kaidalov). Similar-station selection isn't honoring genre/artist similarity.
- Likely cause: genre tags are still "Unknown"/sparse for these tracks (embedded genre extraction quality), so the similar logic falls back to ~random. Check `AppModel` similar-station builder + `autoplayScore`, and verify genre is actually populated (use the real server / a rescan after the artwork+metadata fixes).
- Also a known low: `RadioView` genre grouping vs `AppModel.tracks(forGenre:)` use mismatched normalization (trim/case) — align them.

## ROUND-2 ROBUSTNESS (from the adversarial bughunt; mediums/lows not yet done)

- **FTP:** per-operation timeouts + task-cancellation (silent server hangs forever); reuse a pooled logged-in control connection across range reads (+ `ABOR` on partial RETR); LIST/MSDOS dates in server TZ + Dec→Jan rollover; `parseUnix` filename trim. Needs device testing.
- **SFTP:** `resolvedPath` forces absolute, breaking home-relative `basePath` (e.g. `Music` → `/Music` not `~/Music`); error mapping via typed SFTP status codes not substring match; list vs stat symlink consistency; Settings action to clear `ssh_known_hosts.json` when a host key legitimately changes.
- **MediaStore (#33):** `replaceMediaItems` delete-then-insert reassigns every track's primary key per scan and cascade-deletes valid `cache_entries` — diff by `identity_key`. FTS5 `media_search` maintained but never queried (search is full-table scan + per-row JSON decode). Cached prepared statements; WAL/DatabasePool.
- **Metadata:** ID3 unsync (0x80) + extended-header (0x40); Ogg/Opus page framing for tags+art; ID3 numeric genre table is truncated at 80 (add 80–191); ID3v1 + AIFF/AAC ID3-in-chunk.
- **Auto-cache:** listening stats written to UserDefaults synchronously on every play (debounce); 3 unsynchronized cache representations; decide whether to wire or delete the unused `FileBackedCacheManager`.
- **Lows:** artist-radio tiles always nil artwork; `recentlyAddedAlbums` not date-ordered + trackCount 0; `LibraryService.stableHash` FNV basis differs from probe's (cosmetic).

## FEATURE BACKLOG (user approved ALL of these — build after the active bugs)

Priority order chosen for impact; each should be a self-contained, fully-finished commit (the user's rule: "one 100% done beats three half-baked").
1. **Playlists + .m3u import** — create/rename/reorder/delete; persist (MediaStore has `playlist_entries`); add-to-playlist from track/album menus; Playlists section in Library + detail/play/shuffle; parse `.m3u`/`.m3u8` from the NAS. Biggest gap.
2. **Gapless + crossfade** — `AVQueuePlayer` (or preroll next item); optional crossfade. Pairs with the existing pre-cache-next work. (Coordinate with the streaming-stall fix — both touch playback.)
3. **Synced lyrics** — `.lrc` sidecar from NAS + embedded ID3 `USLT`/`SYLT`, time-synced in Now Playing.
4. **Online artwork fallback** — Cover Art Archive / MusicBrainz when no embedded/folder art; cached; opt-in (leaves LAN).
5. **CarPlay** — `CPNowPlayingTemplate` + browse templates.
6. **Sleep timer** — stop after N min / end of track. Small.
7. **Sort/filter + resume queue** — sort albums/songs by year/added/play-count; filter by genre; persist + resume the play queue on launch.
8. **Equalizer + Replay Gain** — `AVAudioEngine`/`AVAudioUnitEQ` presets + gain-tag normalization. Largest (moves playback off `AVPlayer` — scope carefully, conflicts with the streaming work).

## DONE (this session, pushed to main)

- `66e26ef` artwork: hi-res FLAC embedded cover via exact PICTURE-block ranged read (+ bounded fallback).
- `0adcbc3` streaming: finish content-info request separately (random-access mode) + per-chunk cache writes.
- `e448f49` pre-cache next queue track for instant skip/advance.
- `8e6f287` fix wave: streaming stall (12MB cap removed), config-load data-loss, MP4 metadata overflow crash, SFTP host-key TOFU + range-read truncation, FTP conn leak/PASV-NAT/truncation check, auto-cache eviction/budget/usage/convergence + play-counted-at-ready.
- Earlier (Codex `cc9b753` + prior): FTP/SFTP adapters, GRDB swap, metadata-at-scan, Radio tab, remote artwork at scan, folder picker, local files, Library/search/Now-Playing polish.
