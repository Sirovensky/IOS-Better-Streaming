# Implementation log

## Dead-code removal + polish evening-out — 2026-06-30 (eve)

**Discussed/decided:** After a max-effort adversarial bird's-eye review, the user set the goal: commit current work as a revert point, clean up the binary (remove/merge unused code), and even out polish across visuals / core / other surfaces rather than obsessing over the player. Then run an adversary-review agent, fix, respawn until nothing surfaces.

**What was implemented:**
- Checkpoint commit `dfb647a` (25-bug batch + artwork drop) as the revert point.
- Removed orphaned Core modules `PlaybackCore` (670 LOC) + `CacheManager` (756 LOC) — compiled into the app via the umbrella product but never imported (app runs `PlaybackEngine` + `LibraryService` instead). Deleted their sources + test targets. Package `swift test` 48 pass; app links + builds.
- Added the app target's first XCTest bundle (`BetterStreamingTests`) with 8 AutoCacheController tests (pure scoring/planner logic that had shipped a bug). Wired via `project.yml` + `xcodegen generate`.
- Two audit agents (foreground general-purpose; the first two background attempts flaked with 0 tool-uses) reviewed non-player UI + backend services and returned verified findings. All HIGH/MED fixed, most LOW fixed; see `CHANGELOG.md [2026-06-30 19:10]` for per-item detail.

**Findings fixed:** TrackRowView VoiceOver menu (app-wide), album-detail download menu (user-flagged QUEUE item), remove-source confirmation, onboarding skip-hatch, mini-player skip-on-failure, queue toggle a11y, Sources a11y + tap target, eviction protects playing/preloaded track, atomic stream→complete promotion, moveQueueItem unshuffled sync, didLoadLibraryFromDisk guard ordering, artwork write-side stores filename, Offline stale-filter, Radio empty-state centering, folder-picker retry/disable, dead "coming soon" UI removal.

**Deferred (with rationale):** queue duplicate-track-id current-item matching (needs a per-entry identity, refactor risk); `localRootURL` stale-bookmark surfacing (local-source edge); `Artwork.swift` remote downsample (latent — no live caller); iPad/landscape adaptive layout (product decision — recommend portrait-only iPhone or a real adaptive pass); HomeView `heavyRotation` per-render sort memoization (needs profiling; caching risks staleness).

**Verification:** sim build + `xcodebuild test` green (core 48 + app 8); device build/install to follow. Status: complete pending adversary-review loop.



## Bughunt fix batch — 2026-06-30 (eve)

**Discussed/decided:** User asked for a 5-Opus-agent bughunt over this session's uncommitted work, then set the goal "fix all found bugs." The hunt found 25 (2 HIGH / ~14 MED / ~9 LOW), triaged into `QUEUE.md` (`## BUGHUNT 2026-06-30`). All 25 fixed via 5 parallel implementation agents on disjoint file groups, plus one follow-up edge (crossfade raised mid-track dropping a staged preload).

**What was implemented:** see the `CHANGELOG.md` entry `[2026-06-30 17:06]` for the per-bug detail. Grouped by surface: VoiceOver transport/dismiss (combine scoping), artwork rate-limiter reentrancy + Lucene escape + magic-byte image check, per-session stream scratch file, background-teardown op guard, conclusive-only artwork attempt marking, EQ-on-preload / gapless-off-cancel / crossfade-vs-gapless / playNext-unshuffled, cacheState→libraryRevision bumping + offline playableContext + per-source prefetch, metadata-override path-stable fallback + orphan prune + empty-field guard, auto-cache bulk-play damping + reconcile cancellation, queue dup-track keying + blank lyrics sheet + empty SF Symbol.

**Files changed:** `Features/Player/MiniPlayerView.swift`, `Features/Library/DetailViews.swift`, `Features/Settings/SettingsView.swift`, `Services/OnlineArtworkClient.swift`, `Services/LibraryService.swift`, `Services/RemoteStreamingService.swift`, `Services/PlaybackEngine.swift`, `Services/AutoCacheController.swift`, `AppModel.swift`, `Packages/BetterStreamingCore/Sources/MediaStore/MediaStore.swift`, `Packages/BetterStreamingCore/Tests/MediaStoreTests/MediaStoreTests.swift`.

**Verification:** app build SUCCEEDED on the sim (UDID F6BF298F-…); full core package suite 63/63 pass including 3 new MediaStore tests (`replaceMediaItemsPreservesSurvivingIDAndCacheEntry`, `metadataOverrideSurvivesIdentityKeyChange`, `emptyOverrideFieldsDoNotBlankScannedValues`). Status: complete, NOT yet installed to the device.

**Decisions worth noting:** the override identity-drift fix used the fallback-match approach (path-stable prefix parsed from the length-prefixed `stableKey`, self-contained in MediaStore) rather than adding a `pathStableKey` to `RemoteItemIdentity` in the domain package — same effect, smaller blast radius, no migration. `reconcileAutoCache`'s coarse "network up?" flag was left as-is (it's not the per-source prefetch bug; making it per-source would change eviction semantics).

## App Store submission recon — 2026-06-30 (eve)

**Discussed/decided:** User wants to ship to the App Store. An Opus recon agent inspected the repo + web-verified the 2026 process. No code changed — findings captured in `QUEUE.md` (`## APP STORE — submission recon`). Top blockers: missing 1024px app icon, missing `PrivacyInfo.xcprivacy`, unset `ITSAppUsesNonExemptEncryption`, distribution signing not configured, missing ATS `NSAllowsLocalNetworking`, the `Wellz26/swift-nio-ssh` fork on a version range. Fastest path to users = TestFlight internal (no beta review). Not yet actioned.

## Reconciled top-7 (IDEAS.md) — 2026-06-30

**Discussed/decided:** After a no-code ideation pass, 11 sub-agent threads were reconciled into a curated top-7 in `IDEAS.md`. The directive was to build all 7 and verify each in the iOS Simulator (the phone was away), then install to the device at the end. Status: complete.

**How each was verified (sim, UDID F6BF298F-…, via the `-uiPreview` harness + screenshots):**

1. **Resume hero + mini-bar** — `f1_hero_resume.png` (hero + "Resume at 1:24"), `f1_home_minibar.png`. `engine.resume()` already seeks to the saved elapsed (verified in `PlaybackEngine`); the hero gates on `hasRestorableSession` and hides once playing.
2. **Perf pass** — `f2_home_stats.png`. Revision-keyed caches keep `@Observable` reactivity (the getter reads the observed `libraryRevision`, recomputes once per change).
3. **Rediscovery shelves** — `f3_home_top.png` (Haven't-Heard rail populated). Chose a UserDefaults-backed play-event log over a SQLite migration; the 3 history-based shelves are correctly empty/hidden in the sim.
4. **Morph lag** — `f4_morph_mid.png` (cheap material mid-drag), `f4_morph_full.png` (real glass settled). Root cause kept from the prior shadow fix: interactive lensing + 3 screen-blend rim overlays recomputing over a per-frame-resizing shape.
5. **Metadata repair** — `f5_editor.png` (editor opened on a flagged track). Read-time overlay chosen over upsert-time merge so the base scan row stays pristine and a rescan can't clobber edits. Unit test `metadataOverrideOverlaysAndSurvivesRescan` passes.
6. **Audiophile** — `f6_format_chip.png` ("FLAC · 24-bit · 96 kHz"), `f7_albumgain.png` (toggle). Scoped to the safe parts (album gain + format badge); sample-rate switching and gapless-streamed deferred.
7. **Config sharing + a11y** — `f7_qr_share.png` (QR + Share File), `f7_ax5_minibar.png` (mini-bar legible at the max accessibility size while Home scales fully).

**Key design choices (verified, not assumed):**
- A track's `id` equals its `identity.stableKey` equals the override table key — no mapping needed for #5.
- The project uses explicit (non-synchronized) file references, so new views were added to an existing in-target file (`DetailViews.swift`) rather than a new file the build wouldn't see.
- The mini-bar height is load-bearing for the morph geometry, so its Dynamic Type is clamped instead of letting the bar grow.

**Deferred (second wave):** hi-res sample-rate switching, gapless for streamed sources, QR scanning. Plus the still-open slow-swipe-down stuck-mini-player bug from 2026-06-29.

**Build/install:** sim builds via `xcodebuild … -destination 'platform=iOS Simulator,id=F6BF298F…'`; device build + install via `DEVELOPMENT_TEAM=4HFQ952344 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates` → `devicectl device install app --device 45FD6187…`. Installed to the iPhone 17 Pro on 2026-06-30.

---

## [2026-06-30 20:30] Player-morph + Songs-list perf (device feedback)

**Discussed/decided:** Two device-testing reports plus the adversary's last residual.

1. **Full→mini collapse lag** (user: "0.5-1s delay before I can do anything"): the interactive glass surface stayed hit-testable through the settle spring and swallowed list touches. Gated interactivity/hit-testing on `presented` so the list responds the instant the collapse starts. (Committed earlier in this branch; carried here.)
2. **Mid-collapse swipe re-opens** (user: "if the animation didn't end 100%, I can swipe up away from the animation and it still opens"): the mini-bar's expand gesture was live over the still-animating (large) frame during the settle. Added `AppModel.isPlayerMorphSettling`, set around the collapse settle via `withAnimation(_:completion:)`, and gated the mini-bar tap + expand drag on it. Expand is dead until the collapse finishes.
   - `App/BetterStreaming/AppModel.swift`, `App/BetterStreaming/Features/Player/MiniPlayerView.swift`
3. **`.promote` orphan** (adversary round 2 LOW): a crash between the cache promote copy and its atomic rename could strand `<uuid>.<ext>.promote` in the media cache, inflating the storage readout. Launch now sweeps `*.promote` from the media cache dir (real cached files never carry the suffix).
   - `App/BetterStreaming/Services/LibraryService.swift`
4. **Songs list opens in 2-3s at ~3k tracks** (user report): `AllSongsView.songs` re-ran a locale-aware `localizedStandardCompare` sort of every audio track on each SwiftUI body pass (many passes per navigation push). Albums/artists/stats were already `libraryRevision`-cached; Songs was the one derived list that wasn't. Added `AppModel.songsSortedByTitle` (same revision-keyed cache), and the view reads it for the default Title sort, applying the genre filter after the sort (order-preserving). Non-default sorts unchanged.
   - `App/BetterStreaming/AppModel.swift`, `App/BetterStreaming/Features/Library/DetailViews.swift`

**Status:** complete. Device build succeeded and installed to the iPhone 17 Pro. On-device confirmation of the perf win pending user test.

### [2026-06-30 20:55] Follow-up: list memo + `.part` sweep

User re-tested: Songs still 1-2s, "on bigger libraries it would be worse." The model sort cache killed the repeated sort but A–Z sectioning still ran O(n) on every body pass (several per push). Added a view-local `SectionCache<Item>` memo (a plain class in `@State`, populated in `body` without invalidating the view) that builds ordered items + sections once per (libraryRevision, sort/filter variant). Applied to **all three** big lists — Songs, Albums, Artists — for even scaling.

Correctness gate: the memoized song list holds `Track` value copies, so a favourite toggle (which doesn't bump `libraryRevision`) wouldn't refresh the star. Fixed at the source — `TrackRowView` reads live `model.isFavorite(id)` for the star. Cache-state changes already bump `libraryRevision`, so their glyph refreshes via the rebuild.

Adversary round 3 (ran clean, 30 tool-uses): confirmed the settling gate, glass gating, songs-cache equivalence + revision keying, and promote-dir targeting. One LOW — the launch sweep missed the sibling `*.part` download temp (same disk-leak class). Fixed: sweep both `*.part` and `*.promote`. Also corrected the earlier "inflates the usage readout" wording — the live readout sums by hash filename, so orphans are a pure disk leak, not a readout error.

Files: `Features/Library/DetailViews.swift`, `Components/MediaCells.swift`, `Services/LibraryService.swift`. Device build green + installed. On-device perf confirmation pending.

### [2026-06-30 21:10] Adversary round-4 fixes

Round 4 (ran clean, 43 tool-uses) verified the memo has no stale-data path, no SwiftUI "modifying state during update" warning, and no empty-first-frame. One actionable defect (MED): the `.part` sweep only covered SMB — WebDAV/SFTP/FTP stream to their own `<uuid>.download` temp (WebDAVRemoteClient:148, SFTP:123, FTP:123) and rename to `.part` only at the end, so the stranded file for those three is `.download`, unswept. Extended the launch sweep to `*.part` + `*.download` + `*.promote` across both cacheDir and artworkDir.

Reverted the live-favourite row lookup: the adversary confirmed `toggleFavorite`/`toggleAlbumFavorite` → `reconcileAutoCache` → `libraryRevision &+= 1` (unconditional, AppModel:1647), so the memo already rebuilds on a favourite toggle and the star refreshes from the fresh copy. The per-row live lookup was redundant observation.

Pre-existing (NOT from these commits, reported to user for a decision): the "Year" album sort is a no-op because `Album.year` is always nil (no scan-time year parsing; `Track` has no year field). Either wire year from file tags (a scanner feature) or remove the sort option.

Files: `Services/LibraryService.swift`, `Components/MediaCells.swift`. Device build + install pending.
