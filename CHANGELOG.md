# Changelog

## [2026-06-30 20:30]
Two player/cache fixes from device testing plus the adversary's last residual.

- Full-to-mini collapse felt frozen for up to a second: the interactive glass surface stayed hit-testable through the settle spring and swallowed touches meant for the list. It's only interactive/hit-testable while the player is actually presented now, so the list responds the instant the collapse begins.
  - `Features/Player/MiniPlayerView.swift`
- During an unfinished collapse, an upward swipe over empty space could re-open the player, because the mini-bar's expand gesture was live over the still-animating (large) frame. A morph-settling flag now gates the expand tap/drag: they're dead until the collapse finishes.
  - `AppModel.swift` (`isPlayerMorphSettling`), `Features/Player/MiniPlayerView.swift`
- A crash between the cache promote copy and its atomic rename could strand a `*.promote` temp in the media cache, inflating the storage readout. Launch now sweeps those (real cached files never carry the suffix).
  - `Services/LibraryService.swift`

## [2026-06-30 19:45]
Device-test feedback round plus two regressions the adversary review caught. Build green on the simulator; tests pass.

- Full-screen player top controls (grabber + close arrow) sat under the Dynamic Island / camera cutout on the iPhone 17 Pro. The morph host ignores the safe area and there's no NavigationStack to inset, so the grabber now pads by the top inset itself.
  - `Features/Player/MiniPlayerView.swift`
- Mini player was almost flush on the tab bar; raised its float gap to about 15pt of clearance.
  - `Features/Player/MiniPlayerView.swift`
- Downloading an album gave no feedback. Track rows now show a spinner while downloading and a clock while queued.
  - `Components/MediaCells.swift`
- Album menu showed only "Remove Download" the moment one track was cached, with no way to fetch the rest. It now offers "Download" until every track is on disk and "Remove Download" whenever any are (both appear for a partly-downloaded album).
  - `AppModel.swift` (`albumFullyDownloaded`), `Features/Library/DetailViews.swift`
- Remove-source confirmation rendered as an odd floating popover; it's a centered alert now.
  - `Features/Sources/SourcesView.swift`
- Offline Mode dims tracks that aren't downloaded (they can't play offline), the way Apple Music greys unavailable songs. Offline also gained the online lists' sort options (Title / Recently Added / Most Played).
  - `Components/MediaCells.swift`, `Features/Library/OfflineLibraryView.swift`
- Empty "Playing Next" shows a "Nothing up next" line instead of a bare header.
  - `Features/Player/MiniPlayerView.swift`
- Adversary-review regression fixes: the stream-to-complete promote temp is per-session-unique now (a shared name could collide for two concurrent streams of the same track) and is swept on failure; the library-load guard is set before the await again (reentrancy protection) and released only on a transient read error.
  - `Services/RemoteStreamingService.swift`, `Services/LibraryService.swift`

## [2026-06-30 19:10]
Dead-code removal + a polish pass evening the app out beyond the player. Build green on the simulator; core package (48) and new app tests (8) pass.

- Dropped two orphaned Core modules that were compiled into the app but never used: PlaybackCore (a parallel playback controller the app doesn't run) and CacheManager (the app caches through LibraryService). About 1,400 lines out of the binary, and the suite no longer counts passing tests for code that doesn't ship.
  - `Packages/BetterStreamingCore/Package.swift`; deleted `Sources/PlaybackCore`, `Sources/CacheManager`, and their test targets.
- First tests on the app target: AutoCacheController's scoring and keep/evict planner, the one pure and bug-prone piece of app logic. 8 cases covering play-count vs recency order, bulk-play damping, budget bounds, favourite protection, windowed top-played.
  - `App/BetterStreamingTests/AutoCacheControllerTests.swift`, `project.yml` (new test target).
- Accessibility: every song row hid its context menu from VoiceOver (the row was one combined element) — Play Next / Queue / Favourite / Download are now rotor actions. The queue's shuffle/repeat toggles were colour-only and unlabeled; they announce state now. The Sources "more" button got a label and a 44pt target.
  - `Components/MediaCells.swift`, `Features/Player/MiniPlayerView.swift`, `Features/Sources/SourcesView.swift`
- Album detail had only a bare pencil and no way to download the album; it now has a full menu (Play Next, Add to Queue, Download/Remove, Favourite, Edit Album Info) matching the grid cell.
  - `Features/Library/DetailViews.swift`
- Removing a source now confirms first (it deletes the source and its songs from the device); it used to wipe everything on one tap. First-run onboarding gained a "Skip for now" so an unreachable server with no local music can't trap you in the modal. A failed track in the mini-player now offers Skip, not only "clear the whole queue".
  - `Features/Sources/SourcesView.swift`, `Features/Onboarding/OnboardingView.swift`, `Features/Player/MiniPlayerView.swift`
- Auto-cache eviction can no longer delete the file backing the currently-playing or gapless-preloaded track. Stream-to-complete promotion is atomic now (temp + rename) so a crash mid-copy can't leave a truncated file treated as fully cached. Manual queue reorder is no longer lost when shuffle is later toggled off. A transient DB read error at launch no longer strands an empty library for the session. Artwork persists as a bare filename instead of a container-absolute path.
  - `AppModel.swift`, `Services/PlaybackEngine.swift`, `Services/RemoteStreamingService.swift`, `Services/LibraryService.swift`
- Smaller polish: Offline no longer hides cached tracks behind a stale filter; Radio's empty state centers; the folder picker disables "Scan here" while loading / after an error and offers "Try again"; removed dead "coming soon" protocol UI.
  - `Features/Library/OfflineLibraryView.swift`, `Features/Radio/RadioView.swift`, `Features/Sources/RemoteFolderPicker.swift`, `Features/Sources/SourceSetupView.swift`

## [2026-06-30 17:25]
Album covers dropped after a reinstall. Built + installed to the iPhone 17 Pro.

- The DB stored each album's artwork as an absolute file URL, which embeds the app's data-container UUID. That UUID changes on a delete+reinstall, so the cached `<hash>.jpg` (which does survive, in Application Support) became unreachable — blank covers. Artwork file URLs are now rebased onto the current artwork dir by filename at read time, so they survive any container change; a genuinely-missing file resolves to nil so the backfill re-fetches it.
  - `Services/LibraryService.swift` (`resolvedArtworkURL`, applied in `track(fromMediaItem:)`)

## [2026-06-30 17:06]
Bughunt fix batch — 5 Opus agents found 25 bugs across this session's uncommitted work, all fixed. App build green on the simulator; 63/63 core package tests pass (3 new). Not yet installed to the device.

- Accessibility (HIGH): the mini-player's `.accessibilityElement(.combine)` flattened the whole row, hiding the play/pause + next buttons from VoiceOver entirely; the error row hid its dismiss button the same way. Combine now scopes to the text only; transport + dismiss buttons are individually actionable with labels.
  - `Features/Player/MiniPlayerView.swift`
- Online artwork (HIGH): the MusicBrainz/Deezer rate-limiter read its timestamp, slept, then wrote it — concurrent callers fired together and could trip a 503 ban. The slot is now reserved synchronously before the sleep. Also: Lucene-escape the query, and reject non-image (HTML error) responses by magic bytes.
  - `Services/OnlineArtworkClient.swift`
- Streaming cache (MED): per-session partial scratch file was keyed by track id, so replaying a track let an evicted older session's teardown delete the live file → corruption/stall. Keyed per-session UUID now. Also: backgrounding no longer tears down a client mid-download/artwork (in-flight op counter), and a transient artwork-fetch failure no longer marks an album permanently "attempted" for the session.
  - `Services/LibraryService.swift`, `Services/RemoteStreamingService.swift`
- Playback (MED): enabling EQ mid-track left the already-preloaded gapless next track on the stale mix (now updated); turning gapless off didn't drop a staged preload (one extra gapless advance); crossfade + gapless together produced a silence dip instead of a crossfade (preload is now skipped while crossfade > 0, including when crossfade is raised mid-track); "Play Next" lost its position after a later shuffle-off.
  - `Services/PlaybackEngine.swift`, `Features/Settings/SettingsView.swift`
- Library cache state (MED): `tracks[i].cacheState` writes (download, evict, prefetch, etc.) didn't bump `libraryRevision`, so the album grid kept showing "not downloaded" after a download finished — the memoized `albums` cache served stale state. All writes route through a `setCacheState` helper that bumps once. Album "Play Next"/"Add to Queue" now filter through `playableContext` so offline mode can't queue unplayable remote tracks; prefetch checks the specific source's health, not any-source.
  - `AppModel.swift`
- Metadata overrides (MED): user metadata edits were keyed on the volatile `stableKey` (embeds size + mtime), so a server re-tag silently dropped the edit and orphaned the row; overrides were also never deleted with their media item. Overlay now falls back to a path-stable key match (survives size/mtime change), and delete paths prune orphaned overrides by that path-stable key. Empty-string override fields no longer blank a real title.
  - `Packages/BetterStreamingCore/Sources/MediaStore/MediaStore.swift`, `Tests/MediaStoreTests/MediaStoreTests.swift`
- Auto-cache (LOW): `firstPlayedAtEpoch` was written but never read — its documented bulk-play-once damping now applies in `score()`; a rapid re-schedule can no longer double-apply a reconcile (cancellation checks around `applyPlan`).
  - `Services/AutoCacheController.swift`
- Views (LOW): the upcoming-queue list keyed rows by track id, so duplicate tracks broke reorder/delete — keyed by position now; the lyrics sheet could render blank if the track went nil; the genre filter passed an empty SF Symbol name.
  - `Features/Player/MiniPlayerView.swift`, `Features/Library/DetailViews.swift`
- Tests: added coverage for `replaceMediaItems` PK + cache-entry preservation on a surviving identity, override survival across an identity-key change, and empty-override-field protection.
  - `Packages/BetterStreamingCore/Tests/MediaStoreTests/MediaStoreTests.swift`

## [2026-06-30 12:05]
Artist photos (testing deferred). Built green, not yet installed.

- Artist detail pages now fetch a real artist photo from user-selectable online sources, instead of always showing the placeholder glyph. Two keyless sources — Deezer (on by default, broad coverage) and TheAudioDB — each with its own toggle under Settings → Artwork → Artist photos; enabled sources are tried in order until one returns. Photos cache to the persisted artwork dir (so they survive updates and show offline), and a session remembers misses so reopening a page doesn't re-hit the network.
  - `Services/OnlineArtworkClient.swift` (new `ArtistImageSource` + `ArtistImageClient`), `Services/LibraryService.swift`, `AppModel.swift`, `Features/Library/DetailViews.swift`, `Features/Settings/SettingsView.swift`

## [2026-06-30 11:40]
Queue work (testing deferred). Built green on the simulator, not yet installed.

- Various Artists nav: tapping the "Various Artists" subtitle on an opera/compilation album now opens a list of every performer (each to their own page) instead of dead-ending on whoever was first. New `.albumArtists` route + `AlbumArtistsView`; single-artist albums still link straight through.
  - `Features/Library/DetailViews.swift`, `AppModel.swift`
- Bulk "Auto-fix from file names & folders" button wired into Fix Metadata, for libraries with hundreds of flagged tracks. Inference runs off the main actor over a snapshot; overrides apply in one batched pass (id→index map, not O(N×edits)); fills only broken fields; reversible per track; device-only note in the footer.
  - `Features/Library/DetailViews.swift`, `AppModel.swift`, `Services/LibraryService.swift`

## [2026-06-30 11:15]
Persistence + artwork-scan + search-bar feedback. Built, installed to the iPhone 17 Pro.

- Downloads and album covers no longer vanish on every app update. They lived in Caches (which iOS purges and a reinstall wipes); moved to Application Support, with a one-time move of any existing files and exclusion from iCloud/iTunes backup (both are re-fetchable). Per-session streaming scratch stays in Caches.
  - `Services/LibraryService.swift`
- "Fetch missing covers" was a no-op after the first automatic pass: a per-session set skipped albums already tried, so re-tapping scanned nothing. A manual scan now resets that set and genuinely retries (and hits the online lookup when enabled).
  - `Services/LibraryService.swift`, `AppModel.swift`
- Mini player floated up mid-screen on the Search tab (its keyboard auto-opens): the player overlay positions by the GeometryReader's height, which was shrinking under the keyboard. Keyboard-ignore moved onto the GeometryReader so the bar stays parked at the real bottom.
  - `Navigation/RootTabView.swift`

## [2026-06-30 10:54]
Device-testing feedback batch + 2 Opus correctness audits. All built, 60/60 core tests pass, installed to the iPhone 17 Pro.

- Player stuck at half-view on a slow drag-down (needed an app restart): the collapse gesture lives on `NowPlayingView`, which the morph host unmounted mid-drag once `pc` fell below 0.55 — killing the gesture before `.onEnded` settled and freezing `dragFraction`. Host now keeps it mounted for the whole collapse (`pc > 0.55 || presented`); expand path unchanged.
  - `Features/Player/MiniPlayerView.swift`
- Switch a playing track to an uncached one: the old song now fades to silence over ~1s while the new item buffers, instead of blaring at full volume until it loads. New item restores volume; the gapless hand-off, resolve-failure, and superseded-generation paths all end the fade so it can't strand the queue silent.
  - `Services/PlaybackEngine.swift`
- Online cover art: Settings now shows live status (fetching / N missing / all covered) and a manual "Fetch missing covers" button.
  - `AppModel.swift`, `Features/Settings/SettingsView.swift`
- Fix (audit): maintenance writes (duration-on-play, artwork backfill, favorite) full-row upserted the edited in-memory track, poisoning the file-tag base row so "revert to file tags" restored the edit. Now column-scoped DB updates that never touch the text columns. Regression test added.
  - `Packages/BetterStreamingCore/Sources/MediaStore/MediaStore.swift`, `Tests/MediaStoreTests/MediaStoreTests.swift`, `Services/LibraryService.swift`
- Fix (audit): `metadataNeedsAttention` was an uncached O(N) scan read in `SettingsView.body` (re-ran every EQ-slider frame) — now revision-keyed cached. `isFetchingArtwork` could be cleared by a superseded backfill task — now generation-guarded. `autoFixMetadataFromFiles` (not yet wired) no longer overwrites a real title tag and infers names from the disc-stripped folder chain.
  - `AppModel.swift`

## [2026-06-30 10:05]
Reconciled top-7 from IDEAS.md. All built, verified on the iOS Simulator, installed to the iPhone 17 Pro.

- #1 Resume hero: Home hero gates on `engine.hasRestorableSession`, tap resumes at the saved position, hides once playing; mini-bar kept on every tab; player artist/album nav switched from `.sheet` to `.fullScreenCover` so a long list can't be closed by an accidental swipe-down.
  - `Features/Home/HomeView.swift`, `Features/Player/MiniPlayerView.swift`, `Navigation/RootTabView.swift`, `Services/PlaybackEngine.swift`
- #2 Perf: `albums`/`libraryStats` are revision-keyed caches (recompute once per change, not per render); search runs against a prebuilt lowercased haystack.
  - `AppModel.swift`
- #3 Rediscovery shelves: bounded play-event log in the auto-cache for windowed stats; four Home rails (Haven't Heard / Buried Treasure / On This Day / Top This Month), each hidden when empty.
  - `Services/AutoCacheController.swift`, `AppModel.swift`, `Features/Home/HomeView.swift`
- #4 Morph lag: the player uses a cheap static material (no interactive glass, no rim) while a drag is in flight, and resolves the real Liquid Glass on settle — the per-frame lensing over a resizing shape was the jank.
  - `Features/Player/MiniPlayerView.swift`
- #5 Metadata repair: new `metadata_overrides` table overlaid at read time, so user edits survive a tag rescan; track + album editors, revert-to-file, and a "Fix Metadata" review queue. Unit test covers overlay + survives-rescan + clear.
  - `Packages/BetterStreamingCore/Sources/MediaStore/MediaStore.swift`, `Tests/MediaStoreTests/MediaStoreTests.swift`, `Services/LibraryService.swift`, `AppModel.swift`, `Features/Library/DetailViews.swift`, `Features/Settings/SettingsView.swift`
- #6 Audiophile: album-gain ReplayGain mode + Settings toggle; codec/bit-depth/sample-rate badge read from the decoded asset.
  - `Services/AudioEnhancements.swift`, `Services/PlaybackEngine.swift`, `Features/Settings/SettingsView.swift`, `Features/Player/MiniPlayerView.swift`
- #7 Config sharing + a11y: share a source as a QR / `.bettersource` file (no password) and import it back via a file picker; mini-bar Dynamic Type clamped so the fixed-height morph bar can't clip; VoiceOver combined labels on the hero, stat tiles, and format chip.
  - `Features/Sources/SourcesView.swift`, `Features/Sources/SourceSetupView.swift`, `AppModel.swift`, `Features/Home/HomeView.swift`, `Features/Player/MiniPlayerView.swift`

Deferred by design: hi-res sample-rate switching (needs device measurement), gapless for streamed sources (SMB op-lock), QR scanning (camera, device-only).
