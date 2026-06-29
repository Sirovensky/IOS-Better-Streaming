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

### 1. Streaming stall — HARD STALLS FIXED; minor jank remains
Hard "plays then permanent silence" stalls are **fixed** (user-confirmed). Root cause was the "latest-data-request-wins" epoch added earlier: AVPlayer keeps several loading requests alive at once (one long `allToEnd` stream + small bounded probe/seek reads — confirmed on-device, FLAC streams as `allToEnd=true`), and the epoch aborted every request except the newest, killing the active playback stream → `FigByteStream_Remote err=-12871` / `FigFilePlayer err=-12864`. Fix: serve every request independently (cancel only via `didCancel`), per-chunk retry, and an SMB per-read timeout (12s) that resets a wedged connection. Reader pooling kept.

**Remaining minor (not hard stalls):**
- Rapid song-switch can semi-stall ~10s: the single SMB connection (one-request mutex) is busy with prefetch/cache downloads of the previous track; recovers on scrub. → cancel the in-flight prefetch download on track change (`RemoteFileSystemClient.download` has no cancel token yet — add one).
- Scrub to an un-cached position is janky: brief stop, jumps back, then 1–2s stall while it caches the target. Functional but ugly. → improve seek responsiveness / surface buffering at the scrub target.
- **Caching speed / activity indicator** (still wanted): show download speed + buffered-ahead while caching so a buffering pause reads as progress, not a freeze.

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

## FEATURE BACKLOG (user approved earlier — build after active bugs)

1. **Playlists + .m3u import** — biggest gap.
2. **Gapless + crossfade** (`AVQueuePlayer` / preroll). Coordinate with streaming work.
3. **Synced lyrics** (`.lrc` + ID3 `USLT`/`SYLT`).
4. **Online artwork fallback** (Cover Art Archive / MusicBrainz) — opt-in.
5. **CarPlay.**
6. **Sleep timer.**
7. **Sort/filter + resume queue** on launch.
8. **Equalizer + Replay Gain** (moves off `AVPlayer` — scope carefully).

## DONE (this session — not yet committed/pushed unless noted)

- Streaming hard-stall fix (remove epoch, per-chunk retry, SMB read timeout+reset; diagnosed from device logs).
- Album/artist grouping: folder-keyed albumID, multi-artist credits, Various-Artists display, date-ordered recently-added.
- Remote album-art backfill + now-playing art for streamed tracks.
- Metadata: filename `Artist - Title` parse for untagged; ID3 Win-1251 fallback.
- Offline view real cache-usage readout.
- Album-detail artist tap-through.
- (Earlier pushed) `66e26ef` hi-res FLAC embedded cover; `0adcbc3` content-info separate request; `e448f49` pre-cache next; `8e6f287` stall/data-loss/MP4/SFTP/FTP/auto-cache wave; Codex `cc9b753` FTP/SFTP/GRDB/metadata-at-scan/Radio/folder-picker/local-files.
