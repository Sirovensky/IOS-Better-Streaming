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
- **SMBClient is now VENDORED** at `Packages/SMBClient/` (was remote `kishikawakatsumi/SMBClient` 0.3.1; `BetterStreamingCore/Package.swift` uses `.package(path: "../SMBClient")`). It is patched (bounds-checked `ByteReader`, `FileReader` no-progress break — see ACTIVE BUG #1 FIX 8). Do NOT revert to the remote dep without re-applying these patches, or the `EXC_BREAKPOINT` crash-loop returns. Re-pull the upstream only via a patch/merge that preserves them.

## CURRENT STATE — 2026-06-29 (read first)

**Session focus:** streaming stall + scrub + a crash-loop. All landed on the device; user confirmed *"works so far."*

**On device now** (`com.betterstreaming.app`):
- ✅ **Silent scrub fixed** — serialize SMB ops per client (FIX 6). User-verified.
- ✅ **Underrun-skip fixed** — `AVPlayerItem.preferredForwardBufferDuration = 10` (FIX 6 buffer). User-verified.
- 🔄 **Rapid-scrub cushion** — post-seek pre-roll gate (FIX 7). Installed; *needs final user test* (2–3 scrubs in a row → short spinner → resume with ~5s buffered).
- ✅ **Crash-loop fixed** — vendored SMBClient + bounds-checked `ByteReader` (FIX 8). Launch-verified on device: survives 25s of background SMB maintenance, no `EXC_BREAKPOINT`.

(Mechanisms: see ACTIVE BUG #1, FIX 1–8.)

**Repo:** changes are **uncommitted / not pushed**. Touched: `Packages/SMBClient/` (NEW vendored pkg), `Packages/BetterStreamingCore/{Package.swift, Sources/SMBRemote/SMBRemoteClient.swift, Tests/…}`, `App/BetterStreaming/Services/PlaybackEngine.swift`, `App/BetterStreaming/AppModel.swift`. Commit as `Pavel`, no AI trailer; `git pull --rebase` first (Codex shares the repo).

**Build note:** `Packages/SMBClient` is a local path dep now → after a DerivedData wipe, run `xcodebuild -resolvePackageDependencies` to COMPLETION before building (avoids the "Package.swift modified during build" race). Device build/install recipe: `scratchpad/devbuild_full.sh` (resolve → `xcodebuild build -scheme BetterStreaming -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=4HFQ952344 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates` → `devicectl device install app --device 45FD6187-17F8-527C-BC77-EE065C4FF1FA <app>`; pick the `.app` under `Build/Products/Debug-iphoneos`, **not** `Index.noindex`).

**Laptop disk:** freed ~21G this session → ~39G free. Still reclaimable if needed: Apple Intelligence ~7GB (only via **System Settings → Apple Intelligence & Siri → off**; SIP-sealed, no CLI delete); a **prepared-OS-update** snapshot set (`MSUPrepareUpdate` + os.update local snapshots — install the pending update or delete the snapshots if declined); app caches (Codex 1.8G / Firefox 1G / Telegram 0.9G).

## NEXT TASKS — prioritized, with detail

> Mirrored in the live task list (#7–#12). Streaming was heavily bug-hunted (62 findings / 124 verdicts captured); the highest-value confirmed follow-up is the connection leak (#9).

1. **Verify rapid-scrub pre-roll** (test only). 2–3 fast scrubs → expect a brief spinner then resume with a real cushion. If still thin, raise `PlaybackEngine.prerollSeconds` (currently 5) and/or `preferredForwardBufferSeconds` (10).

2. **Connection-leak fix (#9) — top auto-recovery gap, confirmed CRITICAL by bughunt.** `LibraryService.makeClient` builds a NEW `SMBRemoteClient` (TCP+NTLM+treeconnect) on EVERY call and never disconnects a healthy one — streaming, stat, each prefetch/auto-cache download, artwork per-album, and the artwork backfill (~hundreds of connects/run). Eventually exhausts the NAS session table → new connects hang → unrecoverable stall ("does not auto recover"). **Fix:** cache/reuse ONE `SMBRemoteClient` per `sourceID` in `LibraryService` (open once; reuse for resolve/scan/artwork/download); explicit `disconnect()` on source removal + app background; dedupe per-track artwork (`onTrackStarted` vs `loadArtwork`) and skip when art is already on disk; bound the backfill to one reused client. Also: `download()` still has no per-chunk timeout (a whole-file transfer can't use the 10s read timeout) → add a per-chunk timeout inside `LiveSMBRemoteTransport.download`.

3. **Artist tap in full player → push full Artist screen (#7).** In the Now-Playing/full player, tapping the artist opens a pop-up; it should push the full Artist screen (same destination the album-detail subtitle artist link already uses). Find the player view's artist label; route through the nav path to the existing Artist destination instead of a sheet/popover.

4. **Persist + restore last played song & position (#11).** Save current track ID + `elapsed` (ideally the queue) durably so it survives exit / crash / OS-kill / update. Restore on launch: re-select track, seek to saved position, **paused** (no auto-play). Write periodically (reuse the 0.5s periodic time observer) AND on background/resign-active so a crash still recovers. Persist via MediaStore or UserDefaults. (Pairs with #12.)

5. **Home "pick up where you left off" stuck on same song (#12).** That shelf always shows the SAME track instead of the real most-recent. Find the Home view's data source for it and bind to live recently-played/last-played state (ties into #11).

6. **Station preview song plays first (#8).** On similar/seed stations, selecting a station must start with the EXACT preview song shown on the tile, not a different first track. Make the displayed preview the head of the generated station queue, then continue.

7. **Album long-press context menu (#10).** Long-press an album cell → menu with Download (full album), Favorite/unfavorite, + adjacent actions (Play next, Add to queue, Go to artist). Wire to existing services via SwiftUI `.contextMenu`.

8. **Streaming hardening (lower, after #9):** SMB2 message-id validation in vendored `Connection`/`Session` (responses are matched by ordering only); `Connection.send` round-trip timeout; true cancellation of in-flight prefetch/download on track change.

---

## ACTIVE BUGS (priority order)

### 1. Streaming stall + scrub + crash-loop — FIXED, on device (FIX 1–8; user-verified except FIX 7 pre-roll)
History: (a) the original "latest-wins epoch" aborted ALL but the newest loading request — stall at 0:38. (b) A naive SMB per-read timeout CRASHED: it abandoned an NWConnection read mid-response and then REUSED that connection, desyncing the TCP buffer → `EXC_BREAKPOINT` in `ByteReader.read`, and left the `send` semaphore locked → "scanning forever".

**True root cause (confirmed by reading `recon/repos/SMBClient`):** `Connection.send` serializes every SMB op behind one `actor Semaphore(value:1)`, and `receive()` has **no timeout**. A *silent* network stall mid-receive (Wi-Fi power-save, dropped packet, NAS pause) means the receive completion never fires → the `send` continuation never resumes → its `defer { Task { semaphore.signal() } }` never runs → **the connection's semaphore is permanently locked, wedging that connection forever**. The app only reset the transport when a read *threw*; a hang never throws → unrecoverable stall. Skipping to another track "fixed" it only because that built a brand-new connection.

**Current fix (this session — three layers):**
1. **SMB read + connect timeout with orphan-and-reconnect** (`SMBRemoteClient`): `withTimeout` races the op against a wall clock using UNSTRUCTURED tasks, so a hung read is *orphaned*, not awaited (a structured TaskGroup would block on the hung child). On timeout it throws `.timeout`; `handleFailure` resets the transport **only if it's still the one that failed** (AnyObject identity) and calls the new `disconnect()` → `client.session.disconnect()` → non-blocking `NWConnection.cancel()`. Cancelling the socket makes the orphaned receive error out, which releases the semaphore so the orphaned read unwinds — and we NEVER reuse that connection, so there's no desync/crash (that's why the old timeout crashed and this one doesn't). The existing per-chunk retry then reconnects on a fresh connection. Read timeout 10s, connect 12s.
2. **PlaybackEngine stall watchdog** (catch-all auto-recovery): if `timeControlStatus` stays `.waitingToPlayAtSpecifiedRate` >20s with no elapsed/buffer progress while the user intends to play, auto re-resolve the current item (fresh connection) and seek back to `elapsed` — the automatic version of "skip next & back". Bounded to 3 attempts/item, reset on `.playing`.
3. **Tamed prefetch/auto-cache stampede** (`AppModel`): the next-track full-download prefetch now waits 5s so the live stream establishes its buffer first (both share one Wi-Fi link); auto-cache batch cut 8→3 per pass. Reduces how often contention-induced stalls happen.
4. **Tightened scrub/seek to un-cached positions** (`PlaybackEngine`, reported bug: scrub → plays ~1s at old spot → cursor jumps → "playing but silent" → rebuffer → skips the silent seconds): replaced sample-exact `.zero` seek tolerance with ~1s (AVPlayer lands on a nearby fetchable point fast instead of forcing the exact byte over the loader); coalesce rapid scrubs (`isSeeking` + `pendingSeekSeconds`, stale completions guarded by generation); and the periodic time observer now advances `elapsed` ONLY when `!isSeeking && timeControlStatus == .playing`, so the timer can't run ahead of audio and then skip. Shows buffering during the seek wait; sets `elapsed` from real `currentTime` after.
- Also extended the read timeout/reconnect to `stat()` and `list()` (not just `read()`): a wedged receive during the pre-stream `stat` would otherwise hang resolve where the watchdog can't see it (no player item yet); also bounds the "scanning forever" list hang.
5. **Serialized SMB ops per client** (`SMBRemoteClient`, root cause D — the *actual* "scrub → plays but silent" bug; FIX 4 only addressed the display/timer): the vendored `SMBClient` serializes the wire behind one connection semaphore but allocates each SMB2 message-id **outside** it (`Session.messageId`, a plain class). Two concurrent `client.read`s — AVPlayer's all-to-end fill loop + a scrub's bounded read (`didCancel` is unreliable on device, so the old fill keeps reading) — race the message-id and **desync the protocol → silent hang / garbage audio** (timer advances, no sound), especially on the 2nd consecutive scrub. Added a per-client FIFO async lock (`acquireOpLock`/`releaseOpLock`) held across read/stat/list/download so only ONE op is in flight per connection; the superseded fill loop then just stops issuing new reads. Effectively free (the wire was already serial) and also kills the concurrent shared-`FileReader` use-after-close hazards. **Confirmed by the wave-1+2 bughunt (multiple independent verifiers).**

6. **Forward buffer target** (`PlaybackEngine.loadPlayerItem`): set `AVPlayerItem.preferredForwardBufferDuration = 10` so AVPlayer keeps ~10s buffered ahead (≈0.5 MB MP3 / 1–2 MB FLAC) instead of starting on a tiny default buffer that starves on a slow SMB stream → "plays a moment, lags, then resumes skipping the gap". (User-requested "min ~10s cached".) Verified on device: the silent-skip is gone.
7. **Post-seek pre-roll gate** (`PlaybackEngine.beginPreroll`): `preferredForwardBufferDuration` is only a prefetch hint AVPlayer doesn't honour for *resume-after-seek* (with `automaticallyWaitsToMinimizeStalling` it resumes on a thin <2s buffer — user saw this after 2–3 rapid scrubs). After a seek lands while playing, HOLD playback (player stays paused — AVPlayer still fills `loadedTimeRanges` while paused) until ~5s is actually buffered ahead (or the item is fully buffered / near the end / an 8s wait cap), then resume. Cancelled by a new seek / manual pause / item change; `isPrerolling` keeps the buffering indicator up while held. (Awaiting device verify.)

8. **Vendored SMBClient + bounds-checked `ByteReader` (CRASH FIX).** Recurring `EXC_BREAKPOINT` (often an auto-crash-loop ON LAUNCH): a truncated/misframed SMB response made the vendored `ByteReader` slice `data[offset..<offset+n]` out of range — a fatal Swift trap, **uncatchable by `try`**, so FIX 1's reconnect could never engage. Pre-dates this session's fixes (identical stack at 10:51 on the old build AND 11:19 on the FIX-7 build); hit by background reads (artwork backfill / auto-cache) too, which is why it crash-loops on launch with no user action. SMBClient was a remote SPM dep (`kishikawakatsumi/SMBClient` 0.3.1) so it is now **vendored at `Packages/SMBClient/`** (`BetterStreamingCore/Package.swift` → `.package(path: "../SMBClient")`) and patched: (a) `ByteReader.read<T>()/read(count:)/remaining()` bounds-check and return safe ZERO-filled values of the expected size on underflow instead of trapping → a bad frame becomes recoverable data and the higher layer reconnects; (b) `FileReader`'s three read loops `break` on an empty (no-progress, non-EOF) read so the zero-fill can't cause an infinite 0-byte read loop (bounded anyway by FIX 1's 10s timeout). Verified: SMBRemote compiles against the patched vendored copy. **Follow-up:** also add SMB2 message-id validation in `Connection`/`Session` (responses are matched by ordering only) and a `Connection.send` round-trip timeout.

- Keep: scoped `allToEnd` supersession, pooled `FileReader` per path, `os.Logger` streaming diagnostics (`category streaming`; watch `stall_watchdog`, `read_error`, `timeControl`).
- Verified: 8/8 SMBRemote unit tests pass incl. the hung-read→timeout→disconnect→reconnect test AND a new concurrency-serialization test (`smbSerializesConcurrentOperations`, proves max-in-flight==1); sim streams the real NAS over Tailscale end-to-end with all fixes, no regression.

**Still open (follow-ups, not hard stalls):**
- **Connection lifecycle / leak (root cause C):** `LibraryService.makeClient` builds a NEW `SMBRemoteClient` (TCP + NTLM + tree-connect) on EVERY call and never disconnects — streaming, stat, each prefetch/auto-cache download, and **artwork backfill (up to 40 connects/pass!)**. Over a session this floods the NAS with sessions and can make new connects hang. Wants a per-source client cache + a separate dedicated streaming connection vs. a background-download connection (the "small connection pool" idea).
- True cancellation of an in-flight prefetch/download on track change (SMBClient honours no cancellation; would need the same disconnect trick on a dedicated download client).
- Scrub to an un-cached position: brief 1–2s buffer wait (indicator shows). Bigger win = the connection pool above.

### 2. Album artwork — remote backfill added (VERIFY on device)
Covers were blank because the whole art pipeline only read from a **local** file (so streamed/un-rescanned tracks got nothing). Added: remote artwork extraction (folder cover + embedded ranged read) that works without downloading the track; a throttled library-wide backfill of missing covers (persisted via upsert, no full rescan needed); now-playing/lock-screen art for streamed tracks. Verify covers populate on device.

### 3. Genre is messy → genre radios miss songs (NEW)
Example: Amaranthe tracks are tagged inconsistently (rock / symphonic metal / heavy metal), so a "Heavy Metal" station misses some of their songs. Need genre **reconciliation/canonicalization**: alias/normalize genres (a hierarchy or alias map), and/or derive a per-artist consensus genre, so stations group sensibly. Also align `RadioView` genre grouping with `AppModel.tracks(forGenre:)` normalization. (Old "similar-to-seed picks unrelated genre" issue is downstream of this.)
- **TODO (user): on similar/seed stations, the first song played must be the exact preview song shown on the station tile/card** — make the displayed preview track the head of the generated station queue, then continue with the rest.

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

- **Interactive player transition (REQUESTED — STILL OPEN).** Mini→full and full→mini should follow the finger live (dynamic), not snap after the gesture. Currently a `fullScreenCover` (system transition) + tap to open + chevron/threshold-drag to close. Needs a custom offset-driven container (replace the cover). Deliberately deferred: it's a gesture-heavy change that needs visual iteration, and the Simulator can't be driven headlessly (computer-use needs the user's approval). Shipping it untested risks making the player hard to open/close. Build + iterate when a tappable device/sim is available.
- **A-Z index transliteration — DONE** (Cyrillic/Greek/accented-Latin fold into one Latin index; CJK keep own groups at the bottom).
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
