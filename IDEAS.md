# BetterStreaming improvement ideas (curated)

Written 2026-06-29. Source: a full read of QUEUE.md plus five parallel code explorations
(player/home, library/search, playback engine, metadata, settings/platform). This is the
reconciled short list, not the brainstorm dump. Each "absolute top" item below survived a
cut against four tests: felt every session, uses the self-hosted advantage (your files on
your server, which Apple Music and Spotify cannot touch), already has the scaffolding in the
codebase, and kills a known pain. The full reject list with reasons is at the bottom so the
reasoning is visible.

No code was written for this. These are proposals.

TL;DR. If you do only three things: (1) fix the resume hero, it is nearly free and it is the
open task; (2) add the three cheap rediscovery shelves, they make a big library feel alive;
(3) kill the morph lag, it is your most repeated complaint. A second, risk-averse reviewer
preferred a different order (resume, then offline, then library-at-scale) because those carry the
least risk; both orders are noted at the end. A deeper second pass (see "Round 2") added a strong
fourth: a small performance pass on the list/Home computed properties, because they recompute on
every render and will stutter a large library before any feature matters.

## The frame: three pillars (use this to prioritize, not a flat list)
The app wins by being the best way to live inside your own large, messy, self-hosted collection,
not by being a smaller Apple Music. Every top idea serves one of three pillars:
1. Make the mess beautiful: metadata repair, grouping, artwork. Only possible because the files
   are yours. Deepest moat, higher effort. (idea #3)
2. Make the archive alive: rediscovery, stats, stations over your own play history. Your data,
   mined locally, no external algorithm. Cheapest moat because the signal already exists, and it
   is the emotional reason to open a 10k-track library daily. (ideas #2, #8)
3. Make it feel first-class: the liquid-glass player, gapless, no lag, system presence. Table
   stakes so there is no "hobby app" tax. You are already chasing this. (ideas #1, #4, #5, #6)
If you want the single highest-impact bet, it is pillar 2: it is cheap and it is the hook.
Pillar 3 keeps people from leaving; pillar 1 is what they will tell their friends about.

## Final reconciled top (after both passes, this is the answer)
Everything below this list is supporting detail. After the breadth pass and the deeper second pass,
these seven are the absolute top, roughly in order:
1. Fix the resume hero. Active task, nearly free, also kills two bugs (section 0).
2. Performance pass on the per-render computed properties plus FTS5 search. Cheap hygiene; matters
   more as the library grows. `libraryStats` is the clearest per-render case (Home reads it); not an
   emergency at the current ~860 tracks but it will hitch a 10k library (Round 2).
3. Rediscovery shelves on Home. Three of four work today with no schema change; the play-event log
   adds the fourth and unlocks stats (ideas #2, #8).
4. Kill the morph lag (idea #4). Your most repeated complaint. The shadow/compositing mitigations are
   already in; the remaining lever is the live glass re-blurring the resizing frame. Profile to
   confirm that is the cost before refactoring.
5. In-app metadata repair with a rescan-proof override table and a review queue (idea #3). The
   deepest moat; a build-ready design exists in Round 2.
6. Audiophile correctness. Album-gain and codec/bit-depth badges are safe wins. Hi-res sample-rate
   switching needs a feasibility spike (AVPlayer may ignore `preferredSampleRate` for file playback),
   and gapless-for-streamed is constrained by the SMB single-op-lock, so treat those two as
   investigate / second wave, not quick wins (Round 2 + adversarial pass).
7. Source-config sharing (QR or file, no password) plus the concrete accessibility fixes. The pair
   that decides whether other people in the house, and people using VoiceOver, can use the app at all.
Everything else (system presence/widgets, multi-select and the rest of browse-at-scale, the offline
manager, folder browse, library-state-on-server, scrobbling) is real but second wave. Download-on-
favorite is the one cheap quick win worth pulling forward from that group.

---

## 0. The active decision: "Continue where you left off" vs the mini-player

You changed your mind: keep the mini-player everywhere, AND keep a hero that resumes the last
song at its pause point, but the hero must stop being dominant / duplicate once a track plays.

What is actually wrong today (read from the code):
- At cold launch both the giant hero and the mini-bar show the same paused track (the duplicate).
- The hero does not really continue: on a restored session it skips its `play()` branch
  (because `currentTrack != nil` after restore) and only opens the full player, still paused.
  The user then has to hit play. It never seeks to the saved position by itself.
- Race bug (from the bughunt): if the hero is tapped before restore finishes, `currentTrack`
  is nil, so it plays from 0:00 and throws away the saved session.

Verified in code: `PlaybackEngine.resume()` already does the right thing for a restored
session (`if needsInitialLoad { startCurrentItem(autoPlay: true, resumeAt: elapsed) }`), so the
seek-to-saved-position logic exists. The hero simply never calls it (it calls `play()` or just
opens the player). So this fix is mostly wiring, which makes it low-risk.

Recommendation. Gate the dominant hero on the restore state, not on `isPlaying`:
- Cold (a restored session not yet resumed, i.e. `engine.needsInitialLoad == true`): show the
  big "Continue where you left off" with art, title, a "Resume at 2:34" chip, and a Resume
  button. Tap calls `engine.resume()` (verified to resolve the item and seek to the saved
  second), then opens the full player so you watch it continue.
- After the first resume, or after starting anything (`needsInitialLoad == false`): the big
  hero is gone for the rest of the session. The mini-bar is the single now-playing surface.
  Pausing later does not bring the giant card back.
- Nothing to resume (fresh install): no hero, or a small "Start listening" pointing to Library.
- Revert the Home mini-bar hide. Keeping the bar everywhere also fixes the stuck half-open
  morph bug you just hit (that bug was the hide removing the collapse animation's landing target).

Why this wins: it keys on the one state that means "you have an unfinished session," so the
card helps exactly once per launch and never nags; it wires the hero to the real resume path
(fixes resume-at-position); and because the "Continue" affordance only exists after restore has
run, the 0:00 race disappears. Show the timestamp on the card so "continue" feels trustworthy,
and show a brief loading state on the card itself while the item resolves (a restored stream
takes a moment to seek), so the tap feels acknowledged instead of dead.

This dovetails with idea #2: when the hero recedes during playback, Home should not go empty.
The rediscovery shelves fill it.

---

## THE ABSOLUTE TOP (ranked)

### 1. Fix "Continue where you left off" (see section 0)
Tags: active task, daily, pain-killer. Effort: small. Also fixes the resume-at-position bug,
the pre-restore 0:00 race, and the stuck half-open morph. This is the next thing to build.

### 2. Rediscovery shelves on Home, on a real listening history
Tags: moat, daily, delight. Effort: medium (one small foundation, then cheap shelves).
The home screen today is a hero plus read-only stats, with zero actionable discovery. A big
personal library is mostly a dead archive. The self-hosted advantage is that all the signal is
already yours and local. Add Home shelves:
- On this day: albums added about a year ago today (uses `Track.modifiedAtEpoch`).
- Buried treasure: high play-count tracks not heard in 90+ days (forgotten favorites).
- Haven't heard yet: play-count 0, sampled.
- Top this month: most played in the last 30 days.
Verified in code: `AutoCacheController` already stores per-track `playCount`, `lastPlayedAtEpoch`,
and `firstPlayedAtEpoch`. So three of the four shelves (buried treasure, haven't heard, on this
day) are buildable today with no schema change. Only "Top this month" and the year-in-review
(idea #8) need more: a timestamped play-event log, because `lastPlayedAtEpoch` records only the
most recent play, not how many fell inside a window. That small log is the one foundation to add,
and it is the only thing gating idea #8. Build the three free shelves first.

Caution from the feasibility review: treat the play-event log as its own step, not a prerequisite.
At a large library with frequent sessions the table grows, so cap or roll it up (for example keep
raw events for the trailing 90 days, then fold older ones into monthly counts). Do not block the
free shelves on it.

A cheaper cousin worth stealing: folder-scoped favorites. Let the user favorite a whole album or
folder, then auto-build a "New to your favorites" shelf sorted by when each was added. It reuses
the existing favorite plus added-date fields, needs no history log, and gives most of the
"rediscovery" feel for a fraction of the cost. Good first shelf to ship.

Later, the most distinctive shelf of all: co-play recommendations. Once the play-event log exists,
mine which tracks you tend to play in the same session and surface "you often play these together"
and "because you played X." This is collaborative filtering over your own listening, computed
locally, with no catalog and no account. A cloud service builds this from millions of strangers;
here it is built from you, which is both more private and, for a personal library, more accurate.
Pillar 2 at its strongest.

### 3. In-app metadata repair (server write-back later)
Tags: moat, pain-killer. Effort: medium (phase 1), larger (phase 2).
The library is genuinely messy: mojibake, junk soulseek artist folders, inconsistent genres.
No streaming service can fix this because the files are not yours. Here they are.
- Phase 1 (local, instant, non-destructive): edit title / artist / album / genre / artwork for a
  track or whole album, persist to the MediaStore via the existing upsert (already
  non-destructive), regroup. This alone fixes browsing and grouping with zero server risk.
- Phase 1.5: a "needs attention" review queue that auto-surfaces likely-bad tracks
  (mojibake-detected, 0 duration, junk artist = download-folder name) so fixing is a triage list,
  not a hunt.
- Phase 2 (opt-in, backup-first): write corrected tags back to the file on the server, or a
  sidecar JSON. Higher risk, so opt-in and reversible.
Pairs with per-folder filename-pattern inference (already designed in QUEUE notes) to bulk-fix
untagged folders.

### 4. Kill the player lag during the morph
Tags: pain-killer, daily. Effort: medium.
You have called the morph laggy three times. The cause is structural: the frosted `glassEffect`
re-blurs a resizing frame every animation frame, and the surface also runs a `compositingGroup`
plus shadow per frame. The pragmatic fix is to stop doing the expensive work while the finger is
moving: during the active drag, draw the surface with a cheap static blur or material, and swap
to the live `glassEffect` only when the gesture settles. A live re-sample mid-motion is not
perceptible, so this is a quality-neutral win. Also drop the per-frame compositingGroup and use a
fixed shadow during the drag. (Note: a pure "fixed-size surface scaled by a transform" is not a
clean fit here, because the mini bar is wide-and-short while the full player is tall, and a
uniform scale cannot morph one rect shape into the other without distortion. The during-drag
static-blur approach avoids that trap.) Caveat: this diagnosis is from reading the view code, not
from Instruments. Profile one slow drag first (Time Profiler + the Animation Hitches template) to
confirm the glass blur is the dominant cost and not, say, the artwork or a layout pass, then cut
the right thing. Do not refactor the morph on a guess.

### 5. System presence: Live Activity + Dynamic Island + widgets + Siri
Tags: daily, platform-native expectation. Effort: medium-high (extensions).
Lock-screen transport already works through the now-playing info center. What is missing is the
glanceable and voice layer:
- Live Activity + Dynamic Island: now playing on the island, with skip and a live progress ring.
- Home and Lock-Screen widgets: now playing, recently played, and a one-tap "Continue."
- App Intents so Siri and Shortcuts can run "play my metal station," "resume," "sleep timer."
Highest-visibility polish; it is what makes the app feel like a first-class music app.

### 6. Browsing at scale (a bundle of daily friction fixes)
Tags: daily, large-library. Effort: small-to-medium each, do the cheap ones first.
For a 10k-track library the current lists are thin. The high-value subset:
- Multi-select with batch actions (add to playlist / queue / favorite / download).
- Search scopes plus typeahead plus recent searches (search is plain substring today).
- Swipe actions on rows (favorite / queue / add to playlist).
- Jump to now playing from any list.
- A sticky Play / Shuffle bar on long lists.
And the perception of speed: the album grid decodes artwork synchronously inside the lazy grid
(the library review flagged this), so scrolling a few hundred covers stutters. Move decode fully
off the main thread with a placeholder, and confirm the big lists diff by id, not by full struct.
This is the difference between "feels native" and "feels like a hobby app" on a 10k library.

### 7. Offline you can trust and see
Tags: power-user, travel. Effort: small (favorite), medium (manager).
- Download on favorite: hearting a track caches it now and protects it from eviction. Cheap, and
  it makes offline trustworthy (today a favorite can silently evict).
- A Downloads / Storage screen: what is downloaded, what is auto-cached, used vs free, with
  cancel and prioritize. The cache layer exists; it has no window into it.
- Pre-cache the next N tracks on Wi-Fi while charging, so album and playlist listening never
  stalls on a stream. A targeted version the reviewer liked: when the user queues a batch, prefetch
  the next two or three right away (the stream vs background client split already exists), so the
  first track of a fresh queue does not buffer.

### 8. Listening stats and Year-in-Review
Tags: delight, moat, cheap once #2 exists. Effort: small on top of the history log.
Slice plays by artist, album, genre, week, month. A year-in-review card (top artists, total
hours, most-played day) that you can save as an image. Rides entirely on idea #2's history log,
and it is the kind of thing self-hosters love because the data is theirs and stays local.

---

## STRONG, BUT SECOND WAVE

- Folder / file browse mode. Self-hosters think in folders; a server-tree browser complements the
  tag view and rescues untagged albums. Moat, medium effort.
- Your library state lives on your own server. You already host the music there; host the state too
  (playlists, favorites, play history, settings, and the resume snapshot) as a small JSON or DB on
  the share. This one move gives backup, multi-device sync, cross-device continuity (pause on phone,
  resume at the same second on iPad), and survives a reinstall, with no cloud account. It also fixes
  the current fragility where favorites and stats live only in UserDefaults. This is the
  self-hosted-native version of several separate asks (continuity, backup, multi-user), so it is
  worth treating as one strategic feature rather than piecemeal. Medium-to-large, but high payoff.
- Loudness normalization across albums. ReplayGain is per-track today; album-to-album volume
  jumps are a real annoyance on long sessions. Compute or read album gain.
- Player delight bundle: scrub haptics, swipe-to-skip on the mini-bar, an up-next peek on
  long-press, subtle artwork zoom on the collapse drag. Cheap, makes it feel premium.
- Bonjour source auto-discovery plus credential reuse. Removes most of the onboarding typing for
  home-network users. One-time, but a strong first impression.
- Scrobbling to ListenBrainz / Last.fm. Niche, but the self-hoster audience loves it, and it fits
  the "your data" ethos.

## ALREADY REQUESTED / QUEUED, still worth doing
Track durations missing (rows show no time, library total hidden); light mode; album artwork not
persisting across app updates; the album overflow (...) toolbar menu. These are in QUEUE.md
already; durations and art-persistence are the two daily-felt ones.

## Two foundations under everything (not features, but they decide whether the rest feels good)
- Reliability sweep. QUEUE.md lists confirmed, still-unfixed correctness bugs: gapless preload
  keyed by index instead of track-id (can play the wrong track), play-count double-count on
  stall-recovery (skews Heavy Rotation and therefore rediscovery), `clearQueue` not bumping the
  resolve generation (an in-flight resolve can revive playback). These are cheap and they protect
  trust. A player that occasionally plays the wrong song loses people faster than a missing
  feature. Do a focused pass.
- Accessibility. The mini-bar uses `.accessibilityElement(.combine)`, which hides play and next
  from VoiceOver. Dynamic Type and VoiceOver labels across the player and lists are worth one
  deliberate pass; it is also the cheapest way to widen who can use the app.

## CONSIDERED AND CUT (so the reasoning is visible)
- Waveform visualization: looks cool, low real value, constant CPU, does not help a self-hosted user.
- Share-a-track link: a self-hosted link needs the same server and credentials on the other end, so it rarely works. Revisit only with playlist export.
- iPad keyboard shortcuts, double-tap art fullscreen, artwork parallax: minor; folded into the delight bundle at most.
- AcoustID fingerprinting and content-hash dedupe: powerful but heavy and niche; after the metadata editor exists.
- Adaptive buffer by Wi-Fi SSID: micro-optimization with a privacy cost for little gain.
- Crossfade auto-detect of quiet endings: niche; the manual crossfade already exists.
- Multi-accent / OLED theming: after light mode lands, not before.
- Full per-user profile system: large; the lighter cross-device continuity covers most of the real need first.
- New-music-on-server notifications: fine, but depends on a rescan cadence; second wave.

---

## Suggested order to actually build
Value-first (my order):
1. Idea #1 (resume/hero). It is the open task and small.
2. The three free rediscovery shelves from #2 (start with folder-favorites), defer the play-event log.
3. Idea #4 (morph lag). The recurring complaint.
4. The cheap half of idea #6, plus download-on-favorite from #7.
5. Idea #3 phase 1 (metadata editor), then idea #5 (system presence).

Risk-first (the second reviewer's order, if you want the safest path): #1, then #7 (offline,
low risk and high value), then #6 (library at scale), then either #3 (metadata editor) or the
#2 history log only if you commit to the schema. The reviewer would hold #5 (widgets) until #6
lands, since lock-screen transport already works and widgets mostly add a glance layer.

Both agree: do #1 now.

---

## Smallest shippable cut of each top item
The point is to ship a thin slice, see it on device, then widen. Each first slice below is small
on purpose.
1. Resume hero: gate on `needsInitialLoad`, wire the tap to `resume()`, revert the mini-bar hide.
   Skip even the timestamp chip on the first cut. Roughly half a day.
2. Rediscovery: ship ONE shelf, "Haven't heard yet" (playCount == 0, a random ten, reshuffled each
   app open). Pure existing data, one query, one rail. Add buried-treasure next.
3. Metadata repair: single-track edit of artist / album / title only (the three fields that fix
   grouping), persisted through the existing upsert. No batch, no artwork, no server write yet.
4. Lag: do only the during-drag material swap and measure it. Leave the compositingGroup and
   shadow changes for a second pass if the swap is not enough.
5. System presence: ship the Home and Lock-Screen "now playing" widget first. Live Activity,
   Dynamic Island, and Siri intents come after.
6. Browsing: ship swipe actions on song rows plus jump-to-now-playing first. They are the cheapest
   and the most daily. Multi-select and search scopes follow.
7. Offline: ship download-on-favorite first (a few lines on the favorite toggle). The
   Downloads/Storage screen is a separate, larger slice.
8. Stats: ship the play-event log plus a single "top this month" list. Year-in-review later.

## Rediscovery ranking, concrete (off the existing AutoCacheController stats)
- Haven't heard yet: `playCount == 0`; sample N, reshuffle each app open; bias toward recent
  `modifiedAtEpoch` so fresh imports surface and do not rot unheard.
- Buried treasure: keep tracks where `now - lastPlayedAtEpoch > 90 days`, sort by `playCount`
  descending, and cap per artist so one heavy artist does not fill the rail.
- On this day: albums where `modifiedAtEpoch` is within 7 days of one or more years ago.
- Top this month (needs the play-event log): count events in the trailing 30 days, sort descending.
Each shelf is a horizontal rail; tap plays, long-press reuses the existing context menu; if a shelf
is empty, hide it rather than show a sad empty rail.

## Risks to design around (the parts that bite later)
- Metadata edit vs rescan (the important one): the upsert preserves primary keys, but the next
  scan re-reads the file tags and can clobber a manual edit. Manual edits must be sticky. Add a
  per-field "user override" flag the scan respects, or the editor becomes a trap that silently
  reverts. Decide this before building the editor, not after.
- Resume hero gating: confirm `needsInitialLoad` stays true until an explicit resume and is not
  cleared by some background resolve, or the hero would never appear. Quick check before building.
- Rediscovery on a cold or skewed history: a brand-new user has no plays, so lead with "Haven't
  heard yet" (everything qualifies on day one) and only show buried-treasure once there is history.
  Guard against one bulk-played album dominating every shelf (cap per artist or album).
- Lag fix visual pop: the during-drag material must look close enough to the live glass that the
  swap on settle is not a visible jump. Tune the material so the handoff is invisible.
- Library state on the server: two devices writing at once is last-write-wins unless you version
  it. Stamp each write and merge per list, or accept single-device-at-a-time for the first cut.

---

## Round 2: deeper pass (four sub-agents, two fresh lenses + two build-ready designs)

### NEW top-tier: performance and correctness at real library size
A 50k-track stress read found that several derived collections recompute on every SwiftUI render,
which freezes browsing well before 50k (it bites at a few thousand). This may matter more than any
feature, because if the library stutters, nothing else lands. Most fixes are cheap (cache the
result, invalidate on a track mutation). Confirm each with the profiler first, but the pattern is
real in the code:
- `AppModel.albums` (line 457) regroups all tracks and runs the artist-parser per album on
  every access. Cache it, rebuild only when `tracks` changes. (Verified: both `albums` and
  `libraryStats` are plain computed properties with no backing cache or `lazy`, so any view that
  reads them in `body` recomputes the whole thing each render.)
- `AppModel.libraryStats` (around line 490) iterates every track plus a stats lookup each, per
  render. Cache and update on play.
- `rebuildIndex` runs the credited-artists regex per track unmemoized; memoize per unique artist
  string (a 50k library has maybe a few hundred unique artists).
- Search filters all tracks linearly on each keystroke, while the FTS5 table already exists and is
  never queried (QUEUE.md notes this too). Wire search to FTS5.
- Scan is single-threaded (one probe at a time); parallelize probes with a small bounded group so a
  rescan is minutes faster, without exhausting SMB sessions.
- The artwork cache never evicts. Add an LRU/age cap and a "clear artwork cache" action.
- All tracks live in RAM. Fine for now; only revisit (paged/SQLite-backed) if memory bites on old
  devices at very large libraries.
Treat the per-render caching items as a small, high-return correctness pass. Strong candidate for
the top three alongside the resume hero.

### NEW top-tier: source-config sharing (the household unlock)
A non-technical housemate abandons the app at "type your server password" on every device. Let the
setup device export the source config (host, share, path, username, NOT the password) as a QR code
or a small `.bettersource` file; the other device scans or opens it and the onboarding form is
prefilled (they enter only the password). Cheap, and it is the gate in front of the entire
multi-device and household story. Pairs with Bonjour discovery, but solves the credentials-reuse
half that discovery does not.

### Audiophile correctness (revised after the adversarial pass)
Two are safe wins; two are riskier than they first looked, so they are flagged honestly.
- Album-gain ReplayGain mode (SAFE). ReplayGain is track-only today; add a track/album/off setting
  so concept albums keep their dynamics. Straightforward.
- Codec and bit-depth badges in Now Playing (SAFE, and it is the honest audiophile win). Read the
  FLAC STREAMINFO / asset properties and show "FLAC 24/96", "MP3 320". Always works, builds trust.
- Sample-rate switching for hi-res (NEEDS A SPIKE). The session uses `.default` and never sets
  `preferredSampleRate`, so a 24/96 file may downsample to 48 kHz. BUT `preferredSampleRate` is a
  hint and AVPlayer may not honor it for file (non-HLS) playback. Do a one-hour spike to confirm the
  output rate actually changes before promising "fixes hi-res." If AVPlayer ignores it, this is not
  buildable on the current player and should drop off the list.
- Gapless for streamed tracks (HARD, demote to second wave). The preload guards on cached/prefetched
  only, on purpose: the SMB pool serializes ops behind one op-lock per connection (QUEUE.md root
  cause D), so preloading a second streamed track contends with the live stream. This is
  architecturally constrained, not a quick win. It needs the dual-connection work first.
Second wave: USB-DAC route-change auto-switch, exclusive output mode, DSD recognition.

A reviewer proposed a streaming quality/bitrate selector as a safer substitute. It does not fit
here: the sources are raw files over SMB with one file per track and no transcoding, so there is no
set of qualities to pick from. Skip unless a transcoding server is ever added.

### Accessibility, made concrete (upgrades the foundation note)
- Fixed-size icon frames (`frame(width: 30)` style) and `lineLimit(1)` stat labels collapse at the
  largest Dynamic Type sizes; allow wrap and use scaled frames. Test at accessibility size 7.
- VoiceOver read-order: the mini-bar combines into one element (hides play/next); the full player
  has no deliberate order. Label each control and group artwork+title as one routable element.
- Several secondary-on-surface text pairs fall below contrast at large sizes; bump them.
- Honor Reduce Motion for the morph (cross-fade instead of the liquid expand).

### Build-ready design captured: rediscovery + play log
A new `play_events` table in the MediaStore (id, media_item_id, played_at, with indices and a
CASCADE on delete), written fire-and-forget in `AppModel.notePlayed` right after
`autoCache.recordPlay`, pruned to about a year / ~100k rows. Key result: "Haven't heard"
(playCount == 0), "Buried treasure" (now - lastPlayedAtEpoch > 90d, weighted by playCount), and
"On this day" (album `modifiedAtEpoch` ~ k years ago) all work TODAY from the existing
`AutoCacheController` stats with zero schema change; only "Top this month" needs the new table
(group-count over the trailing 30 days). HomeView slots the rails after the hero, hides empty ones.
Full file:symbol design (schema, queries, integration, edge cases, build checklist) was produced
and can be dropped into a design doc when you start the work.

### Build-ready design captured: metadata editor that survives rescan
The sticky problem solved with a separate `metadata_overrides` table keyed by `identity_key` (the
same key the scan reuses). The override is merged into the row inside `upsertMediaItem`, so the scan
keeps re-reading file tags but the user's value always wins, and deleting the override row restores
the scanned value. Editor covers title/artist/album/genre/year/art (artist/album edits recompute
albumID/artistID and regroup). A review queue auto-flags the likely-bad tracks (U+FFFD mojibake,
0-duration, artist == download-folder name) so fixing is triage. Phase 2 write-back is opt-in,
backup-first, ID3 and Vorbis are safe to write, skip MP4 and FTP. Full file:symbol design produced.

---

## Appendix: ready-to-build spec for idea #1 (resume hero)
So the next session can start without re-deciding anything.

States on Home:
- Resumable and cold: `engine.needsInitialLoad == true` (a snapshot was restored and not yet
  resumed). Show the big "Continue where you left off" hero: artwork, title, artist, a "Resume at
  M:SS" chip from the saved elapsed, and a Resume button. Tapping it (or the artwork) calls
  `engine.resume()` and sets `isNowPlayingPresented = true`. Show a brief loading state on the card
  until the item is ready.
- Warm: `needsInitialLoad == false` (user resumed, or started anything). Do not show the big hero
  at all this session. Home leads with the rediscovery shelves and stats. The mini-bar is the only
  now-playing surface.
- Nothing to resume: no snapshot. Hide the hero, or show a small "Start listening" linking to Library.

Also:
- Revert the Home mini-bar hide in `RootTabView` (remove `hideMiniBar` + the `opacity`/
  `allowsHitTesting` gate; keep or drop `selectedTab` as needed). The mini-bar shows on every tab.
  This also removes the stuck half-open morph, since the collapse animation gets its landing target
  back on Home.
- Change the hero tap from the current `if currentTrack == nil { play(...) }; isNowPlayingPresented
  = true` to the resume path above.

Acceptance criteria:
- Cold launch with a saved session: hero shows "Resume at M:SS"; tap continues from that second
  (not 0:00); the full player opens.
- After resuming once: the big hero is gone; the mini-bar carries playback; pausing does not bring
  the giant card back.
- Tapping fast at cold launch never starts from 0:00 (no race), because the hero's resume affordance
  only exists once `needsInitialLoad` is set by restore.
- On Home, a slow drag-down from the full player settles cleanly to the mini-bar (no half-open stick).
