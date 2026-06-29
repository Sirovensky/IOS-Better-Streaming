# Better Streaming — work queue

Living backlog so work survives across sessions. Newest priorities at top of "Open".
Two agents edit this (this one + a "Codex" agent on another PC) — `git pull --rebase` before pushing.

## Open (priority order)

1. **FTP robustness round 2** — (a) per-operation timeouts + task-cancellation: every NWConnection await (connect/send/receive) should race a deadline and `withTaskCancellationHandler { connection.cancel() }` so a silent server can't hang playback forever; (b) reuse a pooled logged-in control connection across range reads instead of reconnecting per read (big streaming latency win) + send `ABOR` when discarding a partial RETR; (c) LIST/MSDOS dates parsed in server TZ (prefer MDTM/UTC; handle Dec→Jan year rollover); (d) `parseUnix` trim filename field. Needs device testing.

3. **SFTP polish** — (a) `resolvedPath` forces every path filesystem-absolute, so a relative `basePath` like `Music` becomes `/Music` instead of `~/Music` (breaks the common NAS-home setup) — resolve relative bases against the SFTP home (don't prepend `/` unless the base starts with `/`); (b) error mapping uses fragile substring matching (EACCES → authenticationExpired) — map on Citadel's typed SFTP status codes instead; (c) list() vs stat() disagree on symlinks (lstat vs follow) — make consistent. Plus: surface a "host key changed" recovery action in Settings (clear `ssh_known_hosts.json`).

4. **MediaStore re-scan churn + perf (#33)** — `replaceMediaItems` delete-then-insert reassigns every track's primary key each scan and cascade-deletes still-valid `cache_entries`; diff by `identity_key` (UPDATE/INSERT/DELETE) to preserve ids + cache rows. Also: FTS5 `media_search` is maintained on every upsert but never queried (search does a full-table scan + per-row JSON decode) — either query the FTS index or drop the table; use cached prepared statements in bulk insert; consider WAL/DatabasePool so a big re-scan doesn't block reads.

5. **Metadata parser correctness round 2** — (a) ID3v2 unsynchronisation (0x80 flag) + extended-header (0x40) handling — currently dropped/garbled tags; (b) Ogg/Opus page framing — comment block read as contiguous bytes, so values/artwork spanning page boundaries corrupt; (c) ID3 numeric genre table truncated at 80 (add Winamp extended 80-191); (d) ID3v1 trailer + AIFF/AAC ID3-in-chunk not parsed. (Crash-on-malformed MP4 atom already fixed.)

6. **Auto-cache polish** — (a) listening stats JSON-encoded to UserDefaults synchronously on every track start (main actor) — debounce/batch; (b) three unsynchronized cache representations (MediaStore.CacheEntry vs Domain.CacheRecord vs file-existence) — unify; (c) consider wiring the unused `FileBackedCacheManager`/`CacheManaging` engine (pins/reservations/quota) OR delete it so there aren't two cache engines. (Eviction/budget/usage/convergence/play-timing already fixed.)

7. **Radio + Home polish (lows)** — artist radio tiles always nil artwork (derive from a track in the group); genre station count vs `tracks(forGenre:)` use mismatched normalization (trim+case-insensitive both sides); `recentlyAddedAlbums` not date-ordered + placeholder trackCount 0; `LibraryService.stableHash` FNV-1a basis differs from the probe's (cosmetic, keys still stable).

8. **Embedded artwork at scan for remote** — already implemented by Codex; verify on device (folder cover + ranged embedded probe) and that it doesn't full-download.

## Supply-chain note
`swift-nio-ssh` resolves to a **fork** `github.com/Wellz26/swift-nio-ssh` (Citadel 0.12.1 points there, range 0.3.4..<0.4.0). We now declare it directly too (to import NIOSSH for host-key TOFU). Worth auditing the fork or pinning to a trusted source / upstream when Citadel moves back.

## Done (pushed to main)

- **Pre-cache next queue track** — on track start, the next queued remote track is downloaded into the (evictable) auto-cache when reachable, so skip/advance plays from disk instantly. Skips local/video/already-cached; cancels+replaces on track change; honors offline + auto-cache-enabled. (Follow-up: cancel the in-flight download on rapid skip — `client.download` has no cancel token yet.)
- **Streaming stall fixed** — removed the 12MB `finishLoading()` cap that faked EOF (the "plays ~9s then stalls" bug). Now serves the full requested range incrementally and lets AVPlayer drive backpressure via `didCancel`. Partial-range caching preserved; truncate-once (no per-chunk truncate); fully-streamed tracks promoted into the media cache (instant next play / offline); bounded session map; stale partials reclaimed on launch; content-type fallbacks for flac/mp3/m4a/wav/aiff.
- **Data-loss fixed (critical)** — a failed/unreadable `sources.json` no longer reads as "no sources" and wipes the SQLite library / discards `library.json`; config-load outcome is tracked and destructive prune/migration is skipped unless configs are authoritative.
- **Metadata crash fixed** — MP4 64-bit atom size no longer integer-overflow-traps on crafted/truncated files (overflow-free remaining-space check).
- **SFTP security + correctness** — host-key TOFU (records key on first connect, rejects a changed key) replaces accept-anything MITM hole; `read(range:)` loops until the full range/EOF instead of truncating large ranges to one packet.
- **FTP** — data connections always `cancel()`ed (`defer`) so no NWConnection/FD leak; PASV uses the control host (ignores NAT-private advertised IP); download verifies received==expected size (rejects silent truncation).
- **Auto-cache** — manual downloads (`.cached`, pinned) vs auto-cache/streamed (`.prefetched`, evictable) now persisted in an index so eviction/budget actually bound the cache across refresh/relaunch; favourites bounded by budget; reconcile re-schedules so the hot set converges past 8/pass; usage reports auto-bytes only; a "play" is counted at `.readyToPlay`, not on load (failed tracks no longer inflate recency).
- Earlier: SMB scan robustness; folder picker; local files source; Library Play/Shuffle + search; album covers at scan; Now Playing fixes; metadata-at-scan; Radio tab; FTP/SFTP adapters; GRDB swap; remote artwork at scan.
