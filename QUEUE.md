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

## APP STORE — submission recon (2026-06-30, NOT yet actioned)

Opus recon (repo inspect + web-verified 2026 process). Blockers ordered by what stops submission first:
1. **No app icon** — `Assets.xcassets/AppIcon.appiconset/` has only `Contents.json`, no 1024×1024 PNG → Validate/upload rejected. Add a 1024px sRGB no-alpha PNG.
2. **No `PrivacyInfo.xcprivacy`** — app uses required-reason API `UserDefaults` (6+ files) → ITMS-91053 rejection since May 2024. Add manifest: `NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`, `NSPrivacyTracking=false`, collected-data=[]. (swift-nio/swift-crypto/GRDB already ship their own; none on the signature-required list.)
3. **`ITSAppUsesNonExemptEncryption` unset** in Info.plist → "Missing Compliance" blocks TestFlight every build. Set `NO` (SSH/TLS are standard/exempt crypto).
4. **Distribution signing not configured** — `project.pbxproj` has `CODE_SIGN_IDENTITY="iPhone Developer"`, no `DEVELOPMENT_TEAM`/`CODE_SIGN_STYLE`. Set team `4HFQ952344` + Automatic.
5. **ATS missing** — WebDAV uses http `URLSession`; no `NSAppTransportSecurity`. A plaintext LAN WebDAV box is blocked. Add `NSAllowsLocalNetworking=true` (no review justification; avoid blanket `NSAllowsArbitraryLoads`). SMB/FTP/SFTP are raw sockets, ATS-exempt.
6. **Supply chain** — `Package.swift:57` depends on `github.com/Wellz26/swift-nio-ssh` over range `0.3.4..<0.4.0` (fork, pins rev a05e6bb). Pin exact rev or vendor it like SMBClient. Licenses all clean (Citadel/SMBClient/GRDB MIT, NIO/crypto Apache-2.0; no GPL).
7. LOW: version metadata inconsistent (Info.plist literals `1.0`/`1` vs build settings `0.1.0`); no `LSApplicationCategoryType` (set `public.app-category.music`); verify `AutoCacheController.applyPlan` isn't a no-op (2.1 completeness).

Good already: `NSLocalNetworkUsageDescription`+`NSBonjourServices` present; `UIBackgroundModes=[audio]`; creds Keychain-only (`kSecAttrAccessibleAfterFirstUnlock`), never UserDefaults/logs; no demo data; CarPlay inert (no entitlement in build → nothing to approve to submit).

**Fastest to users = TestFlight internal** (≤100 testers, NO beta review, available after processing). External (≤10k public link) needs a one-time light Beta App Review. Full release also needs: screenshots (6.9"/6.5" iPhone + 13" iPad since `TARGETED_DEVICE_FAMILY=1,2`), App Privacy questionnaire ("Data Not Collected"), age rating, support URL + privacy-policy URL (both required). Build via Xcode Organizer Archive→Validate→Distribute, or Transporter for the IPA. Xcode 16+/iOS 26 SDK mandatory for new submissions from 2026-04-28. **Biggest review risk:** reviewer has no NAS → supply a demo server + creds (or a screen recording) in App Review notes, and state plainly it plays the user's OWN media over their OWN servers (pre-empt a 5.2.3 piracy reflex).

## BUGHUNT 2026-06-30 (5 Opus agents) — ALL 25 FIXED + verified (build green, 63/63 tests). Uncommitted.

Whole-app sweep over the uncommitted accurate-duration / crossfade / live-EQ / gapless / metadata-override / two-client work. 2 HIGH, ~14 MED, ~9 LOW — **all fixed this session** (see CHANGELOG `[2026-06-30 17:06]` + IMPLEMENT.md). App build SUCCEEDED on the sim; full core package suite 63/63 pass (3 new MediaStore tests). NOT yet installed to the device — device-verify the VoiceOver transport, gapless/crossfade interactions, download-badge refresh, and metadata-override survival across a re-tag. Original triage retained below for reference.

**HIGH:**
- **VoiceOver: mini-player transport is unreachable.** `MiniPlayerView.swift:103-104` `.accessibilityElement(children: .combine)` flattens the row → play/pause (:74-82) + next (:84-93) buttons vanish as actionable elements. VO user can't pause/skip from the mini bar at all. Same bug on the error-row dismiss/clear-queue button (:44-45 combine over :32-40). FIX: drop `.combine` (default containment), or expose buttons via `.accessibilityCustomAction`.
- **Online-artwork rate-limiter reentrancy.** `OnlineArtworkClient.get` (:65-79) + `ArtistImageClient.get` (:166-176): reads `lastRequestAt`, awaits `Task.sleep`, THEN writes — two callers during one sleep compute delay off the same stale stamp → fire MusicBrainz simultaneously, violating the 1.1s contract (UA gets 503'd). Triggered by a live `remoteAlbumArtwork` racing the backfill. FIX: reserve the slot synchronously before sleeping (`let slot = max(now, last+1.1); lastRequestAt = slot`), no await between read and write.

**MED — playback/audio (PlaybackEngine/AudioEnhancements):**
- **Stale EQ on a gaplessly-advanced track.** `enhancementsDidChange` (:798-810) updates only `currentPlayerItem`; the already-preloaded next item keeps its old `audioMix`, and `gaplessAdvanced` (:567-602) deliberately skips `configureItemAudio`. Enable EQ mid-track → next (preloaded) track plays with NO EQ its whole duration. FIX: also `configureItemAudio(preloadedNextItem)` in `enhancementsDidChange`, or re-run it in `gaplessAdvanced`.
- **Toggling Gapless OFF doesn't cancel a staged preload.** No `onChange(of: gaplessEnabled)` anywhere (`SettingsView.swift:185-190`); `enhancementsDidChange` never touches preload. One more gapless advance happens after disabling. FIX: onChange → `clearPreload(); preloadNextIfGapless()`.
- **Crossfade + Gapless = silence dip, not crossfade.** `preloadNextIfGapless` (:534) has no crossfade guard → envelope fades A to 0, then AVQueuePlayer hard-advances to B which fades up from 0: a near-silent gap. FIX: skip preload when `crossfadeSeconds > 0.1`, or mutually exclude in Settings.

**MED — networking/artwork (LibraryService/RemoteStreamingService):**
- **Stream partial-cache file shared by track.id → eviction deletes a live file.** `streamCacheFileURL` keyed on `track.id` (`LibraryService.swift:1526-1529`); replay/re-resolve spins a 2nd `RemoteStreamSession` on the SAME `partialCacheURL`; evicting the old session at the 8-cap calls `teardown()` (`RemoteStreamingService.swift:194-196`) deleting the file the live session is reading → short/garbage reads, corruption/stall. FIX: key the scratch file on the session UUID, not track.id.
- **Background teardown aborts in-flight downloads/artwork.** `handleEnteredBackground` (:1292-1298) guards only `!scanInProgress`; backgrounding mid-`download` disconnects `backgroundClient` → download throws, `.part` deleted, returns nil. FIX: add an `inFlightBackgroundOps` counter to the guard.
- **Backfill marks transient-failed albums as "attempted."** `backfillAlbumArtwork` (:1011-1017) inserts into `attemptedArtworkAlbumIDs` BEFORE `remoteAlbumArtwork` runs → a timeout/disconnect marks a real-cover album done-for-the-session. FIX: only mark attempted on a conclusive result (success or confirmed-absent), not on a thrown op.

**MED — app state (AppModel):**
- **cacheState writes don't bump `libraryRevision` → `albums` serves a stale download badge.** 6+ sites: `download` :1321/:1325, `removeDownload` :1333, `downloadAlbum` :1383, `maybeCacheMostlyPlayed` :1441, `prefetchNextIfNeeded` :1593, `applyPlan` :1529/:1542, `onTrackStarted` :1506-1508. `computeAlbums` derives `album.cacheState` from these but the memoized getter short-circuits on the unchanged rev. Download an album → tile keeps showing "not downloaded" until an unrelated rev bump. FIX: bump rev after each cacheState write (or a `setCacheState` helper).
- **`playAlbumNext`/`addAlbumToQueue` bypass the offline-playable filter.** :1341-1359 enqueue raw `tracks(forAlbum:)` not `playableContext(...)`; offline mode queues unplayable remote-only tracks → stall/skip. Every sibling intent routes through `playableContext`. FIX: wrap both.

**MED — data store (MediaStore):**
- **Overrides never deleted with their media item → orphan + silent resurrect.** `deleteMediaItems(keeping:)` :1429, `(sourceID:)` :1403, `deleteAllMediaItems` :1449 never touch `metadata_overrides` (keyed on `identity_key` string, no FK/cascade). Removing a source orphans every override; a file with the same `stableKey` reappearing re-applies a ghost override. FIX: `DELETE FROM metadata_overrides WHERE identity_key NOT IN (SELECT identity_key FROM media_items)` in each delete path, same txn.
- **Override identity rides on volatile `stableKey` (size+mtime).** `Identity.swift:154-165` `stableKey` embeds size+modifiedAt and is BOTH `media_items.identity_key` and the override PK. A re-tag on the server (or NAS mtime drift across reconnects) mints a new key → the user's correction silently stops overlaying AND orphans. The "survives rescan" test (`MediaStoreTests.swift:236`) rescans a byte-identical item so it never exercises this. FIX: key overrides on a path-stable identity (source+share+normalizedPath) decoupled from size/mtime.

**MED — views (MiniPlayerView):**
- **Queue list breaks on duplicate tracks.** `ForEach(upcoming, id: \.element.id)` :829-845 keys by `track.id` but the queue allows dupes → `.onDelete`/`.onMove` hit the wrong row. FIX: key by the enumerated `.offset` (already in the tuple).
- **Error-row dismiss unreachable under VoiceOver** (same combine bug as HIGH #1).

**LOW (worth a cleanup pass):**
- `playNext` inserts into `queue` at currentIndex+1 but APPENDS to `unshuffledQueue` → shuffle-off later loses the "play next" position (`PlaybackEngine.swift:253-260`).
- `firstPlayedAtEpoch` written (`AutoCacheController.swift:9,124`) but never read in `score()` → documented new-bulk-play damping doesn't happen. Use or delete.
- `scheduleReconcile` (:184-207) can't stop an in-flight reconcile past the 800ms sleep → rapid re-schedule can double-apply. Add an `isCancelled` check after `applyPlan`.
- prefetch reachability check is global not per-source (`AppModel.swift:1581`) → can pull from a down source if any source is up. `reconcileAutoCache` :1599 same.
- MusicBrainz query not Lucene-escaped (`OnlineArtworkClient.swift:38-41`) — `"`/operators in album/artist break the query.
- Cover-art accepts a >512-byte HTML error page as `.jpg` (:57-62) — no magic-byte (JPEG FFD8 / PNG 89504E47) check.
- No negative cache for genuinely cover-less albums on the direct `remoteAlbumArtwork` path (:905-922) → every replay re-lists the folder + re-probes + re-hits the online lookup.
- Lyrics sheet renders blank if the track goes nil while open (`MiniPlayerView.swift:580-587`). Fall back to `ContentUnavailableView`.
- Genre-filter menu passes an empty SF Symbol name for unselected rows (`DetailViews.swift:485`) — invalid-image log. Use two Labels / a Picker.
- `applyOverride` treats `""` as a real override (`MediaStore.swift:1015-1023`) but `isEmpty` only checks nil → an empty-string field blanks the title and lingers. Treat empty/whitespace as nil on write.
- FTS5 `media_search` maintained on every write but never `MATCH`ed (`MediaStore.swift:423-427` does an in-Swift scan) — dead write cost, and it'd surface stale base text (no overrides) if ever wired up. Wire or drop.

**Test gaps:** the non-destructive `replaceMediaItems` (PK + `cache_entries` preservation for SURVIVING identities) has zero coverage — `mediaStoreCanBulkListReplaceAndDeleteMediaItems` only swaps to a different identity_key (insert+delete branch). Add: upsert item → attach a cache_entry → `replaceMediaItems` with the SAME identity → assert id unchanged AND cacheEntry survives.

**Cleared as NOT bugs (don't re-investigate):** seek-coalescing/generation guards, retain cycles (all long-lived Tasks `[weak self]`), Swift-6 isolation (all 3 services `@MainActor`), empty-queue/repeat-one/nil-track edges, artwork-dedup `albumArtworkTasks` coalescing, scan reuse-key/prune, scrubber-vs-morph gesture scope, EQ band-count bounds, morph drag-fraction reset on track-nil, override overlay coverage (all read paths covered), `upsertMetadataOverride` ON-CONFLICT (caller does read-modify-write merge).

## CURRENT STATE — 2026-06-30 (read first)

**Reconciled top-7 (from IDEAS.md) — ALL IMPLEMENTED, VERIFIED IN THE iOS SIMULATOR, then built + INSTALLED to the device (iPhone 17 Pro 45FD6187…).** The phone was unavailable during the build, so each was verified on the booted sim (UDID F6BF298F-…) via the `-uiPreview` launch-arg harness + `simctl io screenshot`.

- ✅ **#1 Resume hero + keep mini-bar.** Home hero gated on `engine.hasRestorableSession` (restored-not-resumed); tap → `engine.resume()` (seeks to saved elapsed) + opens player; hides once playing; mini-bar kept on all tabs (the `hideMiniBar`/`TabView(selection:)` approach was reverted). `MiniPlayerView` artist/album nav is now `.fullScreenCover` (`PlayerNavCover`), not a sheet.
- ✅ **#2 Perf pass.** `AppModel.albums`/`libraryStats` are revision-keyed caches (`libraryRevision` bumped on every mutation site) instead of O(N) per render; search uses a prebuilt lowercased `searchHaystack`.
- ✅ **#3 Rediscovery shelves.** `AutoCacheController` gained a bounded `playEvents` log (`topPlayed(sinceDays:limit:)`). Home rails: Haven't-Heard / Buried-Treasure / On-This-Day / Top-This-Month (each hidden when empty). Sim verified the populated Haven't-Heard rail; the 3 history-based shelves correctly hidden (no play history in sim).
- ✅ **#4 Morph lag.** During a live drag (`dragFraction != nil`) the player swaps interactive Liquid-Glass + 3 screen-blend rim for a static `.ultraThinMaterial` (no per-frame lensing recompute over the resizing shape); real glass + rim return on settle.
- ✅ **#5 In-app metadata repair.** New `metadata_overrides` table in MediaStore (migration `metadata_overrides_v1`), overlaid at READ time on every media-item fetch → survives a tag rescan (proven by unit test `metadataOverrideOverlaysAndSurvivesRescan`). Track + album editors (sheet via `model.metadataEditTarget`), "Revert to file tags", "Fix Metadata" review queue (Settings → Library).
- ✅ **#6 Audiophile correctness (safe scope).** Album-gain mode (`replayGainAlbumMode`; `replayGainDB(preferAlbum:)`) + Settings toggle; codec/bit-depth/sample-rate badge (`engine.currentFormatDetail` from the decoded asset's ASBD). Sim verified "FLAC · 24-bit · 96 kHz" chip + the toggle.
- ✅ **#7 Config-sharing + a11y.** Export a source as a QR + `.bettersource` JSON file (password EXCLUDED — `SourceConfig` never held it); import via file picker → prefills SourceSetupView, password re-entered. A11y: mini-bar Dynamic Type clamped (`...xxLarge`, protects the fixed 64pt morph geometry); VoiceOver combined labels on the resume hero, stat tiles, format chip. Sim verified QR view + legible mini-bar at AX5.

**Deferred (second wave) — NOT done, by design:** hi-res **sample-rate switching** (spike — `AVPlayer` may ignore `preferredSampleRate`, needs device measurement); **gapless-for-streamed** (hard — SMB op-lock serialization; gapless stays cached-only); **QR _scanning_** (camera-only, no sim camera — export QR + file import is the cross-device path).

**DEBUG-only sim harness added** (all `#if DEBUG`, gated on launch args, inert normally): `-editinfo`, `-settings`, `-share` (alongside existing `-uiPreview`/`-bar`/`-mid`/`-resume`).

**Still open (deferred bug, user-reported 2026-06-29):** slow swipe-down from the full player on Home → can stick in a permanently half-open mini-player hiding half the screen (likely no final animation settle point). Not addressed this session.

**Repo:** this session's 7 features are **uncommitted**. Touched: `Packages/BetterStreamingCore/Sources/MediaStore/MediaStore.swift` (+ `Tests/MediaStoreTests/MediaStoreTests.swift`), `App/BetterStreaming/{AppModel.swift, Navigation/RootTabView.swift, Services/{AutoCacheController, PlaybackEngine, AudioEnhancements, LibraryService}.swift, Features/{Home/HomeView, Player/MiniPlayerView, Settings/SettingsView, Sources/{SourcesView, SourceSetupView}, Library/DetailViews}.swift}`. Commit as `Pavel`, no AI trailer, `git pull --rebase` first.

## CURRENT STATE — 2026-06-29 (read first)

**This session (2026-06-29) — NEXT TASKS #2–#7 ALL IMPLEMENTED, UNBUILT (no Mac/toolchain on the agent box this time — needs a Mac build + device verify before commit):**
- ✅ #2 Connection-leak fix — per-source cached stream+background `SMBRemoteClient`, disconnect on removal/background, artwork dedup, download per-chunk timeout.
- ✅ #3 Artist tap in full player → pushes Artist screen (NavigationStack, no more modal sheet).
- ✅ #4 Persist + restore last played song & position (UserDefaults snapshot; restores paused, lazy load).
- ✅ #5 Home "pick up where you left off" stuck — fixed by persisting recents + playback (was falling back to `audioTracks.first`).
- ✅ #6 Similar-station preview song now plays first (seed pinned to head).
- ✅ #7 Album long-press context menu (Play/Play Next/Add to Queue/Download/Favorite/Go to Artist).

See NEXT TASKS entries for per-item detail + file lists + what to VERIFY.

**Repo:** the prior streaming work IS committed (`517b9fd`). This session's #2–#7 are **uncommitted / not pushed**. Touched: `Packages/BetterStreamingCore/Sources/{RemoteFileSystem/RemoteFileSystemClient.swift, SMBRemote/SMBRemoteClient.swift, BetterStreamingSources/SourceConnectionTesting.swift}`, `App/BetterStreaming/{AppModel.swift, BetterStreamingApp.swift, Services/{LibraryService.swift, PlaybackEngine.swift}, Features/Player/MiniPlayerView.swift, Features/Library/DetailViews.swift, Features/Home/HomeView.swift}`. Commit as `Pavel`, no AI trailer; `git pull --rebase` first (Codex shares the repo). **Build first — these were written without a compiler.**

**Build note:** `Packages/SMBClient` is a local path dep now → after a DerivedData wipe, run `xcodebuild -resolvePackageDependencies` to COMPLETION before building (avoids the "Package.swift modified during build" race). Device build/install recipe: `scratchpad/devbuild_full.sh` (resolve → `xcodebuild build -scheme BetterStreaming -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=4HFQ952344 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates` → `devicectl device install app --device 45FD6187-17F8-527C-BC77-EE065C4FF1FA <app>`; pick the `.app` under `Build/Products/Debug-iphoneos`, **not** `Index.noindex`).

**Laptop disk:** freed ~21G this session → ~39G free. Still reclaimable if needed: Apple Intelligence ~7GB (only via **System Settings → Apple Intelligence & Siri → off**; SIP-sealed, no CLI delete); a **prepared-OS-update** snapshot set (`MSUPrepareUpdate` + os.update local snapshots — install the pending update or delete the snapshots if declined); app caches (Codex 1.8G / Firefox 1G / Telegram 0.9G).

## 2026-06-29 (cont.) — UX + audio bug batch (user device-testing)

**Fixed this batch (built + on device unless noted), VERIFY on device:**
- ✅ **Finger-driven player transition** — replaced `fullScreenCover` with an offset/scale overlay driven by a drag fraction; mini↔full tracks the finger, snaps on release. Then reworked to **bloom OUT of the mini bar** (scale+corner-radius+opacity from a low anchor) instead of sliding from the screen bottom. Liquid Glass (`glassEffect`, iOS 26) on bar + player surfaces, `.ultraThinMaterial` fallback <26. `RootTabView.swift`, `MiniPlayerView.swift` (`f81070a` + bloom edit, uncommitted). VERIFY: feel, snap thresholds, no gesture fight with scrubber/sliders.
- ✅ **Mini bar floats above keyboard** — fix v1 (`.ignoresSafeArea(.keyboard)` on the bar) DID NOT WORK (bottom-aligned bar still reflowed). Fix v2: `.ignoresSafeArea(.keyboard, edges: .bottom)` on the **ZStack**. `RootTabView.swift`. VERIFY: Search → focus field → bar stays put.
- ✅ **Crossfade janky / fades early / screamer at end** — root cause = wrong song length. (a) `LibraryService.playableItem:616` now builds local/cached items with `AVURLAssetPreferPreciseDurationAndTimingKey` (true VBR duration, not a short estimate). (b) `applyVolume` drives the envelope off `player.currentTime` (smooth) and the periodic observer is now 0.1 s (was 0.5 → 6 steps). (c) removed the "snap to full past reported duration" that caused the screamer. NOTE: streaming path still uses the estimate (precise needs the full file) — crossfade is most correct on downloaded tracks. VERIFY: smooth roll-off, fade ends exactly at real end.
- ✅ **EQ had no effect** — changes were only applied at item load. Added `PlaybackEngine.enhancementsDidChange()` (rebuild EQ mix + ReplayGain on the current item + exact seek-in-place to force AVPlayer to adopt the new `audioMix`); `SettingsView` calls it debounced (350 ms) on EQ/preamp/ReplayGain/crossfade change. VERIFY: toggle EQ + move bands mid-track → audible.
- ✅ **EQ below crossfade in Settings** — moved the Equalizer toggle under the Crossfade slider so toggle + bands sit together. `SettingsView.swift`.
- ✅ **Only 100%-played songs cached** — `AppModel.maybeCacheMostlyPlayed()` (from `onPlaybackTick`): once ≥75% of a >60 s track is heard and it's `remoteOnly`, `ensureCached` the whole file (once per track, respects auto-cache toggle). VERIFY: play most of a streamed song → it becomes cached.

**Player transition — liquid glass (IN ACTIVE VISUAL ITERATION on device):**
- Rewritten as ONE morphing element (`MorphingPlayer` in MiniPlayerView.swift + `MiniPlayerContent`; old `MiniPlayerBar`/overlay removed). A single `glassEffect` surface (`LiquidShape`) grows from the mini bar's computed frame to full screen by drag fraction `p`, finger-tracked. Settle is critically damped (no spring/bounce — user requirement). Per user feedback so far: flat top (meniscus dome removed), **tint 0 / clear glass** (album tint hid the background refraction), player's own `backgroundGradient` cleared to a faint scrim (was an album-colour wall), settle sped to `response 0.4`. Knobs: `PlayerMorph.settle` response (RootTabView), corner bulge `* 18`, content resolve window `[0.6,1]` (MiniPlayerView). Still tuning the feel.
- TODO maybe: album-art "hero" fly (small cover → big cover) — skipped to keep one-element/continuous; offer matchedGeometry version if wanted.

**Light mode — NOT BUILT (requested 2026-06-29):**
- App is dark-only. `NowPlayingView` forces `.preferredColorScheme(.dark)`; `DesignTokens` colours + `appScreenBackground` are dark literals. Need an adaptive theme: make DesignTokens resolve per color scheme (asset catalog colors or `Color(uiColor:)` dynamic providers), drop the forced dark, audit every hard-coded `.black`/`.white`/opacity for both schemes, verify the Liquid Glass player + lists in light. Sizeable; do as a focused pass (candidate for a subagent).

**Album art — requested 2026-06-29:**
- Manual "fetch album art" button (user-triggered art fetch, e.g. in Settings and/or album context menu).
- Fetch status/progress shown in Settings (how many covers fetched / in progress / failed).
- Auto album-cover reload on app update — covers currently require a manual server resync after every update; they should persist across updates and reload automatically. (Likely the artwork cache lives in a dir cleared/invalidated on update, or art isn't persisted in the DB — investigate `LibraryService` artwork cache + `backfillAlbumArtwork` + `attemptedArtworkAlbumIDs`.)

**✅ IMPLEMENTED 2026-06-30 (build green, pending device verify) — Album detail — overflow menu (requested 2026-06-29):** add a top-right three-dot (`ellipsis`) toolbar menu on the album screen (`DetailViews`, the album view with Play/Shuffle) with album-level actions: Download whole album, Favorite, Play Next, Add to Queue, Go to Artist, etc. (Album long-press menu already exists from #7; this is the same actions surfaced as a nav-bar `⋯` button.)

**✅ IMPLEMENTED 2026-06-30 (build green, pending device verify) — top-right is now an `ellipsis` menu with Download/Remove, Favorite, Play Next, Add to Queue, and "Edit Album Info" (relabeled; editor footer already states device-only). Album detail — top-right is an Edit button, want a Download button (requested 2026-06-30):** the album screen's top-right control is an **Edit** button (metadata edit). User wants a **Download** button there instead (download whole album for offline). Also the Edit button is **ambiguous**: unclear whether edits are **local-only or also pushed to the server**. Two parts: (a) swap/raise the top-right to a Download action (offline the album); (b) make the Edit destination scope explicit — label/copy stating "local override only, file/server tags unchanged" (metadata overrides ARE local-only per `metadata_overrides` table — they overlay at read time, never write back to files/server). Check `DetailViews` album header toolbar.

**Player header too low — FIXED 2026-06-29:** removed the double safe-area inset (`NavigationStack` already insets; the morph also re-injected `safeTop`/`safeBottom`). Grabber/chevron/source now sit near the top.

**Player full-open backdrop — FIXED 2026-06-29 (verified on Simulator; pending device confirm):**
- ROOT CAUSE of "black at full open" (survived ~4 blind iterations): `NowPlayingView` wrapped its content in a `NavigationStack`, which paints an **opaque system background** (black in dark mode). It covered the Liquid-Glass backdrop at full opacity (transparent mid-morph → the exact "see-through mid-morph, black at p=1" symptom). Fix: dropped the NavigationStack from the player root (must stay transparent); artist/album nav now via a self-contained **`PlayerNavSheet`** (own stack + bg). `LibraryRoute` made `Identifiable` for `.sheet(item:)`.
- Refraction runs on a **snapshot `UIImage`** of the app, NOT the live `TabView` (a UIKit-backed TabView can't rasterize for a `layerEffect` → SwiftUI's red "unrenderable" placeholder). Snapshot via window `drawHierarchy` on open, cleared on close; nil ⇒ plain clear-glass fallback.
- Glass tuned to brief (see-through + MORE chromatic aberration + "whole-surface edge-like", not violent displacement): `LiquidGlass.metal` = whole-surface gentle lensing + edge-weighted prismatic RGB split; `GlassRimOverlay` = white bevel + prismatic AngularGradient rim + top light. Knobs in `RootTabView.RefractionStrength` (full=11, chroma=3.0, noise=0.28, maxOffset=40).
- VALIDATED on the Simulator over REAL app content (full / mid-morph / collapsed all look premium): capture is now per-platform — `#if targetEnvironment(simulator)` uses `window.layer.render` (captures real content on the sim; `drawHierarchy` is black there), `#else` keeps the device-proven `drawHierarchy`. So the sim refracts the real Home (Good evening, library cards, tab bar) just like the device will.
- LAST STEP: install on the physical device + eyeball it (can't screenshot a physical device via CLI). Device build is green; install was blocked only because the phone was disconnected — retry `devbuild_full.sh` + devicectl install when it's back.
- Simulator visual-iteration harness (all `#if DEBUG`, `-uiPreview` gated, inert in normal launch): `RootTabView.task` + `AppModel.debugPreviewNowPlaying` + `PlaybackEngine.debugSeedNowPlaying` + `DebugBackdrop`. Args: `-uiPreview` (full), `-uiPreview -mid` (mid-morph), `-uiPreview -bar` (collapsed). Build `scratchpad/simrun.sh`; screenshot `xcrun simctl io <sim> screenshot`.

**Player — FROSTED pivot + nav/home (2026-06-29 eve, ON DEVICE, uncommitted):**
- Backdrop is now **frosted** (`glassEffect(.regular.tint(...).interactive())` samples the live app directly — no snapshot/`layerEffect`/Metal). The whole snapshot+refraction path (`BackdropCapture`, `RefractionStrength`, `DebugBackdrop`, `LiquidGlass.metal`, MorphingPlayer `backdrop`/`refractStrength` params) is now DEAD CODE — strip before/at commit. `backgroundGradient` = light white wash (top .2 → bottom .05) to BRIGHTEN the frosted backdrop while it stays very blurry (blur is the glass itself).
- Perf: `NowPlayingView` render gated to `pc > 0.55`; fixed shadow radius; settle `response 0.26 dampingFraction 1.0`. Still **slightly laggy** (inherent to live frosted glass re-blurring a resizing frame each morph frame). Next perf step if wanted: morph via a SCALE transform on a fixed-size glass surface instead of resizing+reblur (bigger refactor).
- **Sheets rejected by user.** Player artist/album nav is now a **`fullScreenCover`** (`PlayerNavCover`, renamed from `PlayerNavSheet`): full viewport, dismiss only via the explicit Close (`chevron.down`) button — a sheet's swipe-down would close a long artist list on an accidental drag. Supersedes the line-70 `PlayerNavSheet`/`.sheet(item:)` note. Library nav stays standard push (no frosted sheets). `MiniPlayerView.swift`.
- **Home mini bar hidden:** the floating bar is a duplicate of Home's hero "NOW PLAYING" card, so it's hidden (`opacity 0` + `allowsHitTesting(false)`) when `selectedTab == .home && p == 0 && !presented`; shows on every other tab and as soon as it morphs open. Needed `TabView(selection:)` + `.tag(AppTab.x)` + `AppTab` enum in `RootTabView.swift`. Open from Home via the hero card (already sets `isNowPlayingPresented`). **← SUPERSEDED + caused a bug, see below.**

**Home hero vs mini-player — DECISION CHANGED (2026-06-29 eve), NOT yet built:**
- User reversed the "hide mini bar on Home" idea. New direction: **keep the mini-player on every tab**, AND keep a hero that **resumes the last song at its pause point**, but the hero must **stop being dominant/duplicate once a track is playing**.
- BUG the hide introduced (user hit it): a slow drag-down from the full player **on Home sticks half-open** — `hideMiniBar` removed the collapse animation's landing target. Reverting the Home-hide fixes it.
- Plan (full spec in **`IDEAS.md` §0 + Appendix**): gate the big hero on `engine.needsInitialLoad` (restored-not-yet-resumed session); hero tap calls `engine.resume()` (already seeks to saved elapsed — verified `PlaybackEngine.resume()` lines 299-302) instead of the current `play()`/open-only (which never resumes, and races to 0:00 if tapped before restore). Once playing, hide the big hero; mini-bar is the single now-playing surface. Revert `hideMiniBar`. Show "Resume at M:SS" on the card.
- **`PlayerNavCover` (done this eve):** player artist/album nav is now a `fullScreenCover` (Close = `chevron.down`), not a sheet — user rejected sheets (a long artist list would close on an accidental swipe-down). Built + on device, uncommitted.

**`IDEAS.md` (new, repo root) — curated product backlog (2026-06-29):** reconciled from 11 sub-agents (5 breadth + 1 feasibility critic + 2 fresh-lens + 2 build-ready designs) + code verification. **Reconciled top 7:** (1) resume-hero fix (above); (2) **perf pass on per-render computed props** (`AppModel.albums`/`libraryStats`/`rebuildIndex` recompute O(N) every SwiftUI render → cache+invalidate; wire search to the unused FTS5 — stutters a big library before any feature matters); (3) rediscovery shelves on Home (haven't-heard / buried-treasure / on-this-day buildable NOW off `AutoCacheController` stats; only "top this month"+stats need a new `play_events` table — full design captured); (4) morph-lag fix (morph resizes the glass frame per-frame → static blur during drag, profile first); (5) in-app metadata repair (rescan-proof via a `metadata_overrides` table keyed by `identity_key`, merged in `upsertMediaItem` so a rescan can't clobber edits; + review queue for mojibake/0-dur/junk-artist — full design captured); (6) audiophile correctness (hi-res **sample-rate switching** — session never sets `preferredSampleRate` so 24/96 downsamples to 48k; gapless-for-streamed; album-gain); (7) source-config sharing (QR/file, no password) + concrete a11y fixes (fixed-frame Dynamic Type breakage, VoiceOver read-order, contrast). Second wave: system presence/widgets, multi-select+search-scopes, offline manager (download-on-favorite is the cheap pull-forward), folder browse, library-state-on-server, scrobble. Plus a reliability sweep (gapless preload keyed by index not track-id; playcount double-count on stall-recovery). Full ranked list + MVP cut per item + risks + two build orders + the two build-ready designs are in IDEAS.md.

**Still OPEN (deferred — need device logs / triage):**
- ⏳ **Multi-scrub plays the previous scrub's audio; clock runs to the end** — scrub to 0:30 then immediately near-end → hear 0:30 while timer shows near-end / past real length. Seek-coalescing logic in `PlaybackEngine.performSeek` looks correct (latest target honoured via `pendingSeekSeconds`); suspect the resource loader serving stale cached bytes for the new range, OR a `resolveGeneration` bump abandoning the seek completion and stranding `isSeeking=true`. NEXT: capture `devicectl ... --console` (filter `BETTERSTREAMING_`) while reproducing.

**Bughunt 2026-06-29 (3 Opus agents, all surfaces) — confirmed findings to triage (NOT yet fixed):**
- Playback: (1) **gapless preload revalidated by index not track-id + in-flight resolve never cancelled** on queue edits → wrong track / broken repeat-one (default path, worst). (2) cache mirror write failure aborts live streaming (low-disk). (3) `clearQueue()` doesn't bump `resolveGeneration` → in-flight resolve can revive playback. (4) gapless+crossfade = double volume dip.
- Library: (1) **embedded TITLE tags starting with a number get truncated** ("99 Luftballons"→"Luftballons") — `LibraryService.resolvedTrackMetadata` runs the tag through the filename track-number stripper. (2) app scan indexes `#recycle`/`@eaDir`/hidden dirs (skips `LibraryScanFilter`). (3) case-fold path collision drops sibling folders on case-sensitive servers. (4) library search not diacritic-insensitive; (5) FTS5 table maintained but never queried; (6) artwork backfill stops after one empty batch; (7) cross-source album merge on shared path.
- UI: (1) **"Pick up where you left off" preempts + discards the saved session** (tap before late `restorePlaybackIfNeeded` → fresh play from 0:00, snapshot thrown away). (2) mini-bar `.accessibilityElement(.combine)` removes play/next from VoiceOver. (3) hit-testing gated on snapped `p` (transient tap-through during close anim). (4) playback errors invisible while full player open. (5) always-mounted `NowPlayingView` decodes 800px art + ticks scrubber while hidden (perf). (6) opacity sliver flash on tiny up-drag (auto-fixed by bloom edit). (7) `dragFraction` reset on track-nil (FIXED this batch). (8) A-Z bar overlaps row "…". (9) hero play glyph doesn't play. (10) empty SF Symbol in genre filter.

## NEXT TASKS — prioritized, with detail

> Mirrored in the live task list (#7–#12). Streaming was heavily bug-hunted (62 findings / 124 verdicts captured); the highest-value confirmed follow-up is the connection leak (#9).

2. ✅ **Connection-leak fix (#9) — IMPLEMENTED 2026-06-29, UNBUILT (needs Mac build + device verify).** Was: `LibraryService.makeClient` built a NEW `SMBRemoteClient` (TCP+NTLM+treeconnect) on EVERY call, never disconnected — streaming, stat, each prefetch/auto-cache download, artwork per-album, backfill (~hundreds/run) → exhausts NAS session table → unrecoverable stall. **Fix landed:**
   - **Per-source client cache, TWO clients per source** (`LibraryService.streamClients` + `backgroundClients`). `streamClient` serves `playableItem` (live reads) ONLY; `backgroundClient` serves scan + artwork + downloads. Split (not one shared) because `SMBRemoteClient.download` holds the per-client op-lock for the ENTIRE transfer — sharing one would stall the live stream during a prefetch download.
   - **`disconnect()` added to `RemoteFileSystemClient`** (default no-op) + real impl on `SMBRemoteClient` (non-blocking socket teardown, lazy reconnect). Called on source removal (`removeSource`) and app background (`AppModel.enteredBackground` ← `scenePhase` in `BetterStreamingApp`; background clients only, stream kept for background audio). Also `SMBSourceConnectionTester` now disconnects its one-shot probe.
   - **Artwork dedupe** (`LibraryService.albumArtworkURLCache` + in-flight `albumArtworkTasks`): coalesces the duplicate `onTrackStarted`+`loadArtwork`(+backfill) calls per albumID onto one remote fetch; session-caches the resolved cover URL. Cleared on rescan.
   - **Download per-chunk timeout**: `LiveSMBRemoteTransport.download` now streams via the pooled `read(path:offset:length:)`, each chunk (+ the size probe) bounded by `SMBRemoteClient.withTimeout` (30s); `SMBRemoteClient.download` routes errors through `handleFailure` so a wedged download tears the connection down instead of holding the background op-lock forever. Mock-transport download test still drives `transport.download` (unchanged contract).
   - **Files:** `RemoteFileSystem/RemoteFileSystemClient.swift`, `SMBRemote/SMBRemoteClient.swift`, `BetterStreamingSources/SourceConnectionTesting.swift`, `App/.../LibraryService.swift`, `App/.../AppModel.swift`, `App/.../BetterStreamingApp.swift`. **VERIFY:** build on Mac; device-test a long session (stream + skip + scrub + artwork backfill) does not accumulate NAS sessions / stall.

3. ✅ **Artist tap in full player → push Artist screen (#7) — IMPLEMENTED 2026-06-29, UNBUILT.** `NowPlayingView` now wraps its content in a `NavigationStack(path:)` and reuses the shared `LibraryRoute` destinations (`.libraryDestinations()`): tapping the artist (and "Go to Album") PUSHES the real Artist/Album screen on top of Now Playing — Apple-Music style — instead of the old modal `.sheet`. Removed the `NowPlayingDetail` enum + `.sheet(item:)`; root nav bar hidden so the grabber stays the only chrome. File: `App/.../Features/Player/MiniPlayerView.swift`.

4. ✅ **Persist + restore last played song & position (#11) — IMPLEMENTED 2026-06-29, UNBUILT.** `AppModel` persists a `PlaybackSnapshot` (queue track IDs + index + elapsed + shuffle + repeat) to UserDefaults: throttled (≤1/5s) via a new `PlaybackEngine.onPlaybackTick` (the 0.5s observer), on track change (`notePlayed`), and forced on `enteredBackground` (survives OS-kill while suspended). On launch (after the saved library loads) `restorePlaybackIfNeeded` re-selects the track via new `PlaybackEngine.restore(...)`, which loads the queue **paused, no network I/O** (`needsInitialLoad` flag); the first resume/seek lazily resolves the item and seeks to the saved position. Lock-screen/mini-bar play → `resume()` → loads + resumes. Files: `PlaybackEngine.swift`, `AppModel.swift`. *(Note: full queue IDs saved each 5s — fine for normal queues; cap if huge queues appear.)*

5. ✅ **Home "pick up where you left off" stuck on same song (#12) — FIXED 2026-06-29 (with #4).** Root cause: `recentlyPlayedIDs` + playback state were in-memory only, so a fresh launch had no current track and an empty recents list → the hero fell back to `audioTracks.first` (always the same song). Now `recentlyPlayedIDs` is persisted (UserDefaults `recentlyPlayed.v1`, restored in `init`) and playback is restored (#4), so the hero shows the real last track and the Recently-Played rail shows real recents. Hero label now keys on `isPlaying` ("NOW PLAYING" vs "PICK UP WHERE YOU LEFT OFF").

6. ✅ **Station preview song plays first (#8) — FIXED 2026-06-29, UNBUILT.** `playSimilarRadio` was calling `engine.playShuffled`, which reshuffled and dropped the previewed seed from the head. Now it pins the seed as the head and plays the rest shuffled (`setShuffle(true)` + `play([seed]+rest, startAt: 0)` — `shuffledQueue` keeps index 0 and shuffles only the tail), so the exact tile song plays first. Falls back to plain shuffle if the seed itself isn't playable (offline + uncached). File: `AppModel.swift`. (Artist/Genre tiles show no specific preview song, so they keep full shuffle.)

7. ✅ **Album long-press context menu (#10) — IMPLEMENTED 2026-06-29, UNBUILT.** `AlbumGridCellStatic` (the album grid cell used by Library / Album+Artist detail / Search) now has a `.contextMenu`: Play, Play Next, Add to Queue, Download/Remove Download (hidden for local sources), Favorite/Unfavorite, Go to Artist. New album-level `AppModel` actions: `playAlbumNext` (inserts reversed to keep order), `addAlbumToQueue`, `downloadAlbum`/`removeAlbumDownloads` (+ `canManageAlbumDownload`/`albumHasDownloads`), `isAlbumFavorite`/`toggleAlbumFavorite` (all-tracks). "Go to Artist" uses a `NavigationLink(value: .artist)` — all 3 host views have `NavigationStack` + `.libraryDestinations()`. Files: `AppModel.swift`, `Features/Library/DetailViews.swift`. **VERIFY:** NavigationLink-in-contextMenu navigation on device (idiomatic but flaky historically); favorite is in-memory only (matches existing per-track `toggleFavorite` — not persisted).

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
- Similar/seed stations now start with the exact preview song from the tile (done 2026-06-29 — see NEXT TASKS #6).
- **TODO (user 2026-06-29): progressive genre-expansion for Similar stations.** Right now a similar station plays basically one genre (and sometimes mostly one album) — too narrow. Desired behavior: **start with a mix of the EXACT same genre, then gradually widen to ADJACENT genres** the further into the station you get (rock → hard rock → metal …), introducing each next-closest genre more and more until similar genres run out. Bound by a genre-adjacency graph so it stays in-family: **never jump to an unrelated genre** (no EDM on a rock station) but **don't ignore neighbors** (metal is fair game on a rock station). Implementation sketch: build/curate a genre-adjacency map (or distance metric) on top of the #3 canonicalization; in `AppModel.similarTracks`/`playSimilarRadio`, order the station by an expanding genre-distance window keyed to queue position (distance 0 first, then 1, 2, …), shuffling within each distance band, and stop once no more in-family genres remain. Also avoid over-weighting the same album (current scoring gives albumID +2 — fine, but the genre widening should dominate as the station runs).

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
- **Artist tap-through:** album-detail subtitle links to the artist. Now-Playing (full player) artist also pushes the Artist screen (done 2026-06-29 — see NEXT TASKS #3).

## HOME SCREEN (NEW)

- "Made For You" playlist is **empty** (nothing pre-populated) — populate it or remove it.
- **Remove "Recently Added"** from Home.
- Add **fun read-only stats** (total listened time, library info, counts) — NOT settings, no setup prompts; just delightful info.

## "COMPLETE ALL" SWEEP — 2026-06-29 (continued, UNBUILT — needs Mac build + test)

Goal: clear the whole backlog. Landed this sweep (each pushed to main):
- **Batch 1** (`fbdcf1a`): repeat-one `hasNext`; prefetch wrap on repeat-all; `downloadAlbum` one-task throttle; no double-count play on stall-recovery; removed dead `toggleFavoriteOnCurrent`.
- **Batch 2** (`1b1e06e`): connect-timeout transport leak (orphaned late connect now disconnected); keep the scan's connection alive on app-background; stop playback when the playing source is removed.
- **Batch 3** (`ec06afd`): ID3 extended-header skip + global unsync (v2.2/2.3) + "ID3" marker search (AIFF/AAC tags-in-chunk); TPE1/ARTIST beats TPE2/ALBUMARTIST; ID3 genre table extended 80–191; non-feature parenthetical artist-split fix.
- **Batch 4** (`f826d08`): `MediaStore.replaceMediaItems` now non-destructive — diff by identity_key, preserves PKs + cache_entries (#33).
- **Batch 5** (`1068a44`): FTP LIST Dec→Jan year rollover. *(Deferred, low-EV for an SMB user: FTP per-op timeout/pooling, SFTP path-resolution + typed errors + known-hosts UI — rewrites of working secondary-protocol code with no FTP/SFTP source to validate.)*
- **Batch 6 (partial)** (`41d025b`): "Go to Artist" from the album context menu now works in every grid (Library/AllAlbums/Search/Player) via an env nav-action (the old in-contextMenu NavigationLink was dead on iOS).

**Also landed this sweep:**
- **Batch 6 rest** (`14b6f6f`): Songs sort (Title/Artist/Recently Added/Most Played) + genre filter; Albums sort (Title/Artist/Recently Added/Year); auto-cache stats writes debounced (flush on background). Home "Made For You" already hidden-when-empty.
- **Batch 7 / #3** (`55ce533`): genre canonicalization was already in place; ADDED progressive genre-expansion similar stations — seed first, same family, then widening to adjacent families via a `genreAdjacency` graph + BFS distance (Rock→Metal yes, EDM no), capped, shuffled within each band.
- **Playlists** (`ac018bf`): full subsystem — create / rename / delete, add-to-playlist from the player menu, **.m3u/.m3u8 import** (filename match), UserDefaults persistence, empty state. `Playlist` is now Codable.
- **Online cover art** (`01b6010`): opt-in `OnlineArtworkClient` (MusicBrainz release search → Cover Art Archive front image, rate-limited 1.1s, proper User-Agent); last-resort fallback in artwork resolution; Settings → Artwork toggle (off by default).

**Batch 8b (the rest, now IMPLEMENTED — all UNBUILT, opt-in features default OFF):**
- **Synced lyrics** (`4447b96`): `.lrc` sidecar parser (`Lyrics.swift`) + a player "Lyrics" sheet that highlights the current line from `engine.elapsed`. Reads the sidecar via the source (local or remote).
- **ReplayGain + preamp + 5-band EQ** (`f7b6237`): `AudioEnhancements` settings (default off); RG/preamp via `player.volume` from the asset's gain tags; EQ via an `MTAudioProcessingTap` (`AudioEQTap.swift`, vDSP biquads, defensive passthrough on any format mismatch). Settings → Audio section. **Only attached when enabled — default playback is byte-identical.**
- **Crossfade** (`1614412`): opt-in single-player track fade-in/out (`crossfadeSeconds`, default 0 = off), composed with the RG base volume. NOTE: this is a *fade*, not sample-gapless — true gapless needs an `AVQueuePlayer` rewrite (still open below).
- **CarPlay** (`12a557f`): browse + Now-Playing template code (`CarPlaySceneController.swift`) wired to `AppModel.shared`. **INERT** until 3 Apple/Xcode steps are done (can't be done/tested from here): add the `com.apple.developer.carplay-audio` entitlement, declare the CarPlay scene in Info.plist's `UIApplicationSceneManifest` alongside the SwiftUI scene, and test on CarPlay hardware/sim. See the header comment in that file.

**True gapless — DONE 2026-06-29 (`ecfa958` Phase 1 + `53f767e` Phase 2), UNBUILT.**
- Phase 1: `AVPlayer` → `AVQueuePlayer` (single-item, no behavior change — `removeAllItems`+`insert`, not `replaceCurrentItem`).
- Phase 2: preload the next track (only when gapless on, playing, not repeat-one, and the next is **already cached/local** → zero streaming contention), enqueued after the current. When the current ends, `handlePlaybackEnded` sees AVQueuePlayer already moved to the preloaded item and runs `gaplessAdvanced` (index/observers/started/volume/art bookkeeping, no re-resolve) → no gap. Preload invalidated on skip/remove/move/shuffle/repeat-change/sleep-timer. Opt-in `AudioEnhancements.gaplessEnabled` (default ON) + Settings toggle. Files: `PlaybackEngine.swift`, `AudioEnhancements.swift`, `SettingsView.swift`. **VERIFY on device:** two downloaded tracks advance with no gap; manual skip / reorder / shuffle / sleep-timer / repeat-one still behave; streaming (non-preloaded) tracks advance as before.

**Genuinely still open (blocked / need device):**
- **CarPlay activation** — the 3 project steps above (entitlement + scene manifest + hardware test); template code is in place.
- Interactive finger-driven mini↔full player transition (needs sim/device gesture iteration); device-verify of artwork backfill + metadata rescans.

## BUGHUNT 2026-06-29 (3 Opus agents, whole-app re-verify of #2–#7)

Verdict: #2–#7 confirmed correct as written (no Swift-6/actor/deadlock/reentrancy errors; #6 seed-pin provably lands at index 0; #3 nav restructure sound). Real bugs found → **FIXED this session (unbuilt):**
- HIGH: source health stayed `.asleep` after a cold launch (only a scan set `.online`), silently disabling prefetch + auto-cache until manual rescan → now `onTrackStarted` marks the source `.online` (`AppModel`).
- HIGH: favorites never persisted (in-memory only) → new `LibraryService.setFavorite` upsert, called from `toggleFavorite` + `toggleAlbumFavorite`.
- MED: SMB `download` could truncate (short/empty read) and cache a corrupt track → `guard offset >= total` + `total > 0` (`SMBRemoteClient`).
- MED: `listFolders` leaked a client per browse → `disconnect()` on exit. SFTP `disconnect()` was a no-op (default) → implemented (`SFTPRemoteClient`).
- MED: won't resume after a phone-call/Siri interruption (session not reactivated) → `setActive(true)` before `resume()` on `.ended`.
- MED: `restorePlaybackIfNeeded` carried stale elapsed onto the head track when the saved track was gone → resets elapsed to 0.
- MED: `playAlbumNext` on an empty queue started on the album's LAST track → plays in order when queue empty.
- MED: "Go to Artist" used a `NavigationLink` inside `.contextMenu` (dead on iOS — detached platter) → now a path-mutating `Button`, wired in Library + Search.
- LOW: restore-seek clamped to 0 when duration unknown; `removeFromQueue` didn't update `unshuffledQueue`; `moveQueueItem`/`setShuffle` matched current track by full-struct equality → match by id.

**Deferred (real, lower-impact / pre-existing — NOT yet done):**
- "Go to Artist" is hidden on the **AllAlbums** grid + detail grids (those hosts don't own a nav path). Thread a path via `libraryDestinations` or an environment nav-action to enable it there.
- Stall-recovery re-fires `onTrackStarted` (new generation) → `recordPlay` double-counts playCount, skewing Heavy Rotation. Guard by track id, not generation.
- `repeatMode == .one` at last index: `hasNext` true but `next()` stops; repeat-one loop runs `beginPreroll` (stutter) + a dead synchronous `play()`.
- `prefetchNextIfNeeded` doesn't wrap to index 0 at end+`.all` (wrap skip not instant).
- `downloadAlbum` spawns one unbounded Task per track (serialized by the background op-lock now, so low impact) — batch it.
- Dead `toggleFavoriteOnCurrent` in the engine (no callers) — remove.
- Connect-timeout-then-success leaks the transport (no deinit/disconnect); `handleEnteredBackground` doesn't cancel an in-flight scan (it reconnects + may skip a folder); removing a source mid-stream lets the live session revive the connection.
- Metadata (LOW, pre-existing): `creditedArtists` keeps bracketed contents → fragments "Artist (Live)" into extra artist IDs; TPE2/ALBUMARTIST can override TPE1 performer via `??` (pollutes grouping); ID3 header flags byte ignored (unsync/extended-header tags get no embedded metadata).

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
