# Better Streaming — work queue & handoff

Self-hosted NAS/server music app (iOS 17 SwiftUI + SwiftPM `BetterStreamingCore`).
Goal: Apple-Music/Spotify-quality player over the user's own SMB/WebDAV/FTP/SFTP/local library. Open-source, multi-user, no demo data.

## Handoff context (read first)

- **A Mac build box with the iPhone 17 Pro attached is available this session.** Claude can `xcodebuild` + install to the device, AND pull the live app DB for diagnosis:
  `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.betterstreaming.app --source "Library/Application Support/library.sqlite" --destination ./library.sqlite`
  Device console logs (our `print()` lines, filter `BETTERSTREAMING_`): `xcrun devicectl device process launch --console --terminate-existing --device <id> com.betterstreaming.app`. Live syslog (CoreMedia/AVFoundation): `idevicesyslog -u <udid>`. The Codex agent on the other PC has **no** toolchain — keep changes buildable.
- **Real test server:** host `SELFHOST-VENUS-SERIES._smb._tcp.local`, SMB share **Swimming**, music under **/Music** (full path `smb://SELFHOST-VENUS-SERIES._smb._tcp.local/Swimming/Music`). User is logged in on device. The build box is NOT on that LAN (can't resolve the `.local` mDNS), so device testing + pulled-DB inspection are the verification path.
- **Two agents share this file** (this one + "Codex"). `git pull --rebase origin main` before every push.
- **Commits:** author `Pavel <sirovensky@gmail.com>`, **no AI mentions/trailers**.
- **Supply chain:** `swift-nio-ssh` resolves to a fork `github.com/Wellz26/swift-nio-ssh` (Citadel 0.12.1 points there; we declare it directly for the SFTP host-key fix). Audit/replace when possible.

## ACTIVE BUGS (priority order)

### 1. Streaming stall — FIXED (verified live in Simulator over Tailscale)
History: (a) the original "latest-wins epoch" aborted ALL but the newest loading request, killing the active playback stream when AVPlayer issued a bounded probe (`FigByteStream_Remote -12871` / `FigFilePlayer -12864`) — stall at 0:38. (b) The SMB per-read **timeout** I then added CAUSED CRASHES: it abandoned an NWConnection read mid-response, desyncing the TCP buffer → `EXC_BREAKPOINT` in `ByteReader.read` (SMBClient), and left the `send` semaphore locked → next op hung forever ("scanning forever"). `SMBClient` exposes no way to cancel the connection, so a safe timeout isn't possible there.

**Current fix (committed):**
- No per-op timeout. Recovery instead via: per-chunk **retry** on transient read errors, and `handleFailure` resets the cached transport on a genuine disconnect so the next op reconnects.
- Serve every request; **scoped supersession**: an `allToEnd` fill loop yields only when a NEWER `allToEnd` request supersedes it (handles orphaned loops when `didCancel` is unreliable). Bounded probe/seek requests never bump or check the epoch — so a probe never kills a fill (no 0:38 regression).
- Pooled `FileReader` per path; `os.Logger` streaming diagnostics (category `streaming`, capture with `log stream`/`idevicesyslog`).
- Verified in the Simulator streaming the real NAS over Tailscale: ~13–25 MB/s, tracks play and auto-advance; orphan-loop contention no longer stalls.

**Remaining minor (not hard stalls):**
- Rapid song-switch can briefly contend (prefetch/cache download of the previous track on the single SMB connection). → cancel the in-flight prefetch download on track change (`RemoteFileSystemClient.download` has no cancel token yet).
- Scrub to an un-cached position: brief stop then 1–2s to cache the target. → surface buffering at the scrub target / **caching speed indicator** (show MB/s + buffered-ahead).
- Bigger throughput win if needed: a small SMB **connection pool** (multiple TCP connections) so concurrent reads parallelize instead of serializing on one mutex.

### 2. Album artwork — remote backfill added (VERIFY on device)
Covers were blank because the whole art pipeline only read from a **local** file (so streamed/un-rescanned tracks got nothing). Added: remote artwork extraction (folder cover + embedded ranged read) that works without downloading the track; a throttled library-wide backfill of missing covers (persisted via upsert, no full rescan needed); now-playing/lock-screen art for streamed tracks. Verify covers populate on device.

### 3. Genre is messy → genre radios miss songs (NEW)
Example: Amaranthe tracks are tagged inconsistently (rock / symphonic metal / heavy metal), so a "Heavy Metal" station misses some of their songs. Need genre **reconciliation/canonicalization**: alias/normalize genres (a hierarchy or alias map), and/or derive a per-artist consensus genre, so stations group sensibly. Also align `RadioView` genre grouping with `AppModel.tracks(forGenre:)` normalization. (Old "similar-to-seed picks unrelated genre" issue is downstream of this.)

## METADATA (deep-dive findings from the live DB — RESCAN needed for fixes to apply)

Pulled `library.sqlite` (860 items). Findings + status:
- **Эпидемия didn't register** — the `Manriel_slskd/2010 Дорога домой` album has **no embedded tags**; path-derivation made artist = the junk soulseek download-folder ("Manriel_slskd") and left the real artist buried in the `NN - Artist - Title` filename. **Fixed:** parse `Artist - Title` from the filename when untagged (split on " - ", guards numeric/empty). NEEDS RESCAN.
  - **TODO (user):** make filename parsing robust — artist may be AFTER the title ("Title - Artist"), or other layouts. Sample MULTIPLE files in a folder to infer the pattern rather than assume `Artist - Title`. Hard to do without edge cases — get a sub-agent to design the rule.
- **"Full Kaidalov MP3" (203 tracks) are mojibake** (`�®¦ª¨ ¡ «¥à¨­`). The **filenames themselves are corrupted on the NAS** (soulseek Win-1251 bytes the NAS can't represent → SMB returns lossy `U+FFFD`). Not recoverable from the filename app-side; VLC shows the same. **User:** known bad archive, no clean copy — wants a way to **clean up on the server** (a rename/retag utility?). If those files DO carry embedded ID3 tags, the Win-1251 fix below now recovers them (tag beats bad filename).
- **Cyrillic ID3 mojibake** — ID3v2 "ISO-8859-1" text frames are frequently mis-tagged Windows-1251 (Russian MP3s). **Fixed:** decode Latin-1, fall back to Windows-1251 when it yields more real letters (safe for genuine Western text). NEEDS RESCAN. (Not yet validated on real tagged data — the Kaidalov sample was filename-level, not tag-level.)

## METADATA / LIBRARY GROUPING (done this session — mostly recompute on launch, no rescan)

- **Album split by feat./compilation FIXED.** `albumID` now keyed on the album **folder + title** (one folder = one album on a NAS; collapses `CD1/CD2` disc subfolders), not the per-track artist. "Moonglow" and the "F*** Me I'm Famous" / "Greatest Hits & Remixes" compilations no longer fragment. Recomputes on launch.
- **Multi-artist credits.** Artist string is parsed into individual artists ("David Guetta feat. will.i.am & apl.de.ap" → 3). Each track is cross-listed under **every** credited artist (featured artist gets the song on their page); the album stays under the **primary** (first) artist. Artists list = one entry per individual. `artistID` = primary. **Caveat:** splits band names containing `&`/`,`/`vs.`/`x` (Above & Beyond, Earth Wind & Fire) — accepted default for a collab-heavy library; add a known-band exception list later if needed.
- **Album display artist** = shared primary, else "Various Artists".
- **recentlyAddedAlbums** now date-ordered with real trackCount + consensus artist.
- **Artist tap-through:** album-detail subtitle links to the artist. **TODO this session:** make the Now-Playing (full player) artist clickable too.

## HOME SCREEN (NEW)

- "Made For You" playlist is **empty** (nothing pre-populated) — populate it or remove it.
- **Remove "Recently Added"** from Home.
- Add **fun read-only stats** (total listened time, library info, counts) — NOT settings, no setup prompts; just delightful info.

## ROUND-2 ROBUSTNESS (from the adversarial bughunt; not yet done)

- **FTP:** per-op timeouts + cancellation; pooled logged-in control connection across range reads (+ `ABOR` on partial RETR); LIST/MSDOS dates in server TZ + Dec→Jan rollover; `parseUnix` filename trim.
- **SFTP:** `resolvedPath` forces absolute (breaks home-relative `basePath`); error mapping via typed SFTP status codes; list vs stat symlink consistency; Settings action to clear `ssh_known_hosts.json`.
- **MediaStore (#33):** `replaceMediaItems` delete-then-insert reassigns PKs + cascade-deletes valid `cache_entries` — diff by `identity_key` (the new art backfill uses `upsertMediaItems`, which is the safe path). FTS5 `media_search` maintained but never queried. WAL/DatabasePool.
- **Metadata:** ID3 unsync (0x80) + extended header (0x40); Ogg/Opus page framing for tags+art; ID3 numeric genre table truncated at 80 (add 80–191); ID3v1 + AIFF/AAC ID3-in-chunk. (Win-1251 fallback + filename Artist-Title now done.)
- **Auto-cache:** listening stats written to UserDefaults synchronously per play (debounce); 3 unsynchronized cache representations; wire or delete `FileBackedCacheManager`.
- **Offline view cache usage** — FIXED (refreshes real on-disk bytes on appear).
- **Lows:** artist-radio tiles always nil artwork; `LibraryService.stableHash` FNV basis differs from probe's (cosmetic).

## OPEN QoL / UX (next)

- **Interactive player transition (REQUESTED).** Mini→full and full→mini should follow the finger live (dynamic), not snap after the gesture. Currently a `fullScreenCover` (system transition) + tap to open + chevron/threshold-drag to close. Needs a custom offset-driven container (replace the cover) — deferred this session because it needs visual iteration and the Simulator can't be tapped headlessly (computer-use needs the absent user's approval). Build + iterate when a tappable device/sim is available.
- **Track durations missing.** The metadata reader parses tags but not audio-frame duration, so `durationSeconds` is 0 → song rows show no time and the Home "in your library" total is hidden. Extract duration via `AVAsset.load(.duration)` when a track is cached, or parse frame headers; persist it.
- **Resume queue on launch** + **sort/filter** (year / date-added / play-count; filter by genre).
- **Kaidalov server cleanup tool** — the mojibake is in the on-disk filenames (bad soulseek import); needs a server-side rename/retag utility (out of app scope) OR rely on embedded tags (Win-1251 fix) where present.
- **Filename pattern robustness** — `splitArtistTitle` assumes `Artist - Title`; artist may be after the title or vary per folder. A sub-agent designed a per-folder pattern-inference approach (sample multiple files, infer the constant=album-artist slot, confidence ladder) — fold it in. Design notes from this session.

## FEATURE BACKLOG (user approved earlier)

1. **Playlists + .m3u import** — biggest gap.
2. **Gapless + crossfade** (`AVQueuePlayer` / preroll). Coordinate with streaming work.
3. **Synced lyrics** (`.lrc` + ID3 `USLT`/`SYLT`).
4. **Online artwork fallback** (Cover Art Archive / MusicBrainz) — opt-in.
5. **CarPlay** (`CPNowPlayingTemplate` + browse templates) — needs the CarPlay entitlement; can't be tested without CarPlay sim/hardware.
6. **Sleep timer** — DONE (Now Playing menu: 5/15/30/45/60 min + end-of-track).
7. **Equalizer + Replay Gain** (moves off `AVPlayer` — scope carefully).

## DEV / TEST NOTES

- **Headless Simulator testing:** the build box reaches the NAS over Tailscale (`100.83.121.63:445`). DEBUG-only launch env hooks (inert without the var): `BETTERSTREAMING_TEST_SMB_PASSWORD` injects the SMB password in-memory (no Keychain in the sim); `BETTERSTREAMING_TEST_AUTOPLAY=<title>` auto-plays a track. Pass via `SIMCTL_CHILD_…`. Inject a real library by copying the device's `library.sqlite`+`sources.json` into the sim app's Application Support and set `onboarded.v1`. Pull the device DB with `devicectl device copy from … --source "Library/Application Support/library.sqlite"`.

## DONE (this session — committed locally, NOT pushed; user builds from this Mac)

Commits: `a4b282e` (streaming/grouping/scan/UX), `8417e04` (sleep timer + stats tile), `bd1004a` (bughunt hardening: artist-split regexes, supersede-finishes-with-error, backfill convergence, reader-pool in-use guard, tolerant scan-reuse key). Verified live in the Simulator streaming the real NAS over Tailscale.


- Streaming: removed the crashing per-read timeout; scoped allToEnd supersession + per-chunk retry + transport-reset-on-disconnect; pooled reader; os.Logger. Crash (`ByteReader` EXC_BREAKPOINT) + "scanning forever" both fixed. Verified live in sim.
- Metadata/grouping: folder-keyed albumID; multi-artist credits (cross-listed); Various-Artists display; filename `Artist - Title` parse; ID3 Win-1251 (Cyrillic) decode; genre canonicalization + per-artist consensus.
- Scan: incremental (reuse unchanged by stableKey) + progress + artwork deferred to backfill (fixes "forever").
- Artwork: remote backfill (folder cover + embedded ranged) + now-playing art for streamed tracks.
- UX: A-Z fast-scroll index (Songs/Albums/Artists, Latin+Cyrillic); unified Offline list+filter; Home read-only stats (Recently-Added removed, empty Made-For-You hidden); tappable artist (album detail + Now Playing); Sources folder count + total size + full base path; Songs Play/Shuffle restored; **sleep timer**.
- (Earlier pushed) `66e26ef`/`0adcbc3`/`e448f49`/`8e6f287` + Codex `cc9b753`.
