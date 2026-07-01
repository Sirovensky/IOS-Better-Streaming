# Creative Direction

Date: 2026-06-28

## Reference status

Local BizarreCRM mockups and design-system files were used read-only as visual references.

The useful inheritance is not CRM branding. It is the visual discipline: warm graphite surfaces, restrained cream/caramel primary actions, teal for operational status, thin borders, solid content cards, glass only for chrome, and setup flows that show progress without becoming decorative.

## Product feel

Build a private hi-fi library, not a network file manager. The app should feel like Apple Music discovered a NAS: tactile, calm, artwork-forward, and reliable under bad network conditions.

The visual center is a warm near-black listening environment with album art as the only loud visual. BizarreCRM's cream/caramel accent becomes the "amplifier light": play, selected source, active offline pack, and the current scan step. Teal becomes connectivity and transfer health. Wine/rose is reserved for favorites, destructive alerts, and missing media.

Default impression:

- Music-first, video-capable.
- Dark mode is the flagship mode.
- Light mode exists and is polished, but should still feel warm and media-focused.
- Dense enough for 50k-track libraries.
- Never "enterprise dashboard", never "generic cloud file browser".

## Color tokens

Use semantic tokens from day one. Do not hard-code hex values in SwiftUI views.

### Core palette

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| `surfaceCanvas` | `#050403` | `#FAF8F5` | Full app background. |
| `surfaceBase` | `#0C0B09` | `#F5F2ED` | Main screen fill, under lists. |
| `surfaceCard` | `#141211` | `#FFFEFA` | Solid cards, album cells, source cards. |
| `surfaceRaised` | `#1B1917` | `#FAF7F2` | Sheets, menus, mini player body. |
| `surfaceChromeGlass` | `rgba(28,25,22,0.56)` | `rgba(255,250,245,0.78)` | Top bars, bottom tab, mini player blur. |
| `borderSubtle` | `rgba(255,250,240,0.08)` | `rgba(30,24,16,0.10)` | Row separators, card edges. |
| `borderStrong` | `rgba(255,250,240,0.16)` | `rgba(30,24,16,0.18)` | Focused fields, selected rows. |
| `textPrimary` | `#F2EEF9` | `#1A1816` | Main copy and row titles. |
| `textSecondary` | `#A8A4A0` | `#5A5550` | Artist, album, source path. |
| `textTertiary` | `#7E7A76` | `#8A847C` | Time, size, bitrate, disabled metadata. |
| `brandPrimary` | `#FDEED0` | `#A66D1F` | Play button, selected tabs, primary setup CTA. |
| `brandPrimaryStrong` | `#FFF7E0` | `#C2410C` | Pressed/active primary, high-emphasis light CTA. |
| `onBrandPrimary` | `#2B1400` | `#FFFFFF` | Text/icons on primary fill. |
| `connectionTeal` | `#4DB8C9` | `#0E7A8A` | Connected, syncing, speed test, info links. |
| `favoriteWine` | `#C5566D` | `#8E2D40` | Favorite, liked playlist, warm editorial accent. |
| `success` | `#34C47E` | `#1F7A4A` | Cached and verified. |
| `warning` | `#E8A33D` | `#8A5200` | Slow network, stale cache, background limit. |
| `error` | `#E2526C` | `#BA1A2E` | Missing source, failed auth, failed download. |

### Album art tinting

Artwork can influence player screens, not library density.

- Extract a dominant color and a contrast color from album art.
- Apply artwork tint only to Now Playing background, lock-screen-style preview, and playlist hero headers.
- Tint strength: 8-16% over dark surfaces, 4-10% over light surfaces.
- Never recolor primary controls from album art. Play remains `brandPrimary`.
- If art is absent, use a generated warm graphite placeholder with a subtle radial cream/teal tint and a media-type glyph.
- Video playback should use true black around content, with graphite controls. Do not force warm backgrounds behind video.

## Typography

Use Apple system typography. BizarreCRM's display fonts are useful as inspiration for hierarchy, but this app should feel native on iOS.

| Role | Font | Size guidance | Notes |
| --- | --- | --- | --- |
| Large screen title | SF Pro Display Semibold | 32-34 pt | Library, Downloads, Sources. |
| Section title | SF Pro Display Semibold | 22-24 pt | Album sections, setup step titles. |
| Row title | SF Pro Text Semibold | 15-17 pt | Track, folder, playlist names. |
| Body / metadata | SF Pro Text Regular | 13-15 pt | Artist, album, NAS path, hints. |
| Captions | SF Pro Text Regular | 11-12 pt | Bitrate, file size, scan count. |
| Technical values | SF Mono / monospaced digits | 11-13 pt | SMB path snippets, speed, duration, storage. |

Rules:

- Track titles get one strong line; artist/album/path gets one secondary line.
- Use monospaced digits for elapsed time, duration, transfer speed, storage used, and scan counts.
- Avoid all-caps headings except tiny labels under 12 pt.
- Do not use condensed novelty fonts in the app UI.
- Dynamic Type must preserve action rows. If text grows, reduce secondary metadata before hiding primary actions.

## Layout language

Use an 8 pt spacing system with compact density as a first-class option for large libraries.

Core dimensions:

- Screen side padding: 16 pt phone, 24 pt iPad.
- Row height: 56 pt default, 48 pt compact, 68 pt comfortable.
- Album grid gap: 12 pt phone, 16 pt iPad.
- Album art corner radius: 8 pt.
- Cards: 8 pt radius.
- Buttons: 8 pt radius for rectangular controls, capsule only for segmented filters and pills.
- Sheets: 20-24 pt top radius.
- Minimum tap target: 44 x 44 pt.

Surface rules:

- Lists are solid surfaces with separators. They should not be a stack of glass cards.
- Glass is for chrome only: navigation bar, bottom tab bar, mini player, transient sheet header.
- Content cards are opaque `surfaceCard` or `surfaceRaised` with thin borders.
- Use left accent bars for selected setup cards and source health cards. Avoid heavy caramel borders on large surfaces.
- Keep the mini player above the tab bar and visually attached to playback state, not as a detached marketing card.

## Iconography

Use SF Symbols. Outline by default, filled only for selected, active, or playing states.

Recommended symbols:

- Playback: `play.fill`, `pause.fill`, `backward.fill`, `forward.fill`, `shuffle`, `repeat`, `repeat.1`, `speaker.wave.2`, `airplayaudio`.
- Queue and library: `music.note.list`, `list.bullet`, `text.line.first.and.arrowtriangle.forward`, `square.stack`, `rectangle.stack`.
- Sources: `externaldrive.connected.to.line.below`, `server.rack`, `network`, `wifi`, `wifi.slash`, `lock.shield`.
- Folders: `folder`, `folder.fill`, `folder.badge.plus`, `arrow.triangle.2.circlepath`.
- Downloads/offline: `arrow.down.circle`, `checkmark.circle.fill`, `clock.arrow.circlepath`, `exclamationmark.triangle`, `externaldrive.badge.xmark`.
- Video: `play.rectangle`, `film`, `pip`, `captions.bubble`.
- Actions: `ellipsis`, `plus`, `magnifyingglass`, `line.3.horizontal.decrease.circle`, `slider.horizontal.3`.

Icon rules:

- Use 20 pt icons in rows and nav bars, 24 pt for primary player controls, 16 pt for status badges.
- Never communicate cache/offline state by color alone. Pair every status color with an icon and label.
- Recursive folder actions need a distinct glyph treatment: folder plus loop arrow, or folder row with a loop badge.
- Do not use emoji in production UI.

## Motion and haptics

Motion should support state changes, not decorate the app.

Timing tokens:

- `motionQuick`: 150 ms for button press, row highlight, scrubber hover.
- `motionSnappy`: 220 ms spring for play/pause swap, mini-player expand, selected segment.
- `motionPage`: 350 ms interactive spring for setup step changes, player expansion.
- `motionGentle`: 500 ms for scan completion, download pack completion, first source connected.
- `motionProgress`: 550 ms ease-in-out for progress arcs and transfer bars.

Motion decisions:

- Mini player expands into Now Playing with matched album art, title, and progress bar.
- Play/pause button uses a short scale pulse plus haptic on state change.
- Queue reordering uses drag lift, shadow, and light haptic; no bouncy row chaos.
- Download progress animates smoothly but never lies. If the app is background-limited, pause animation and label it.
- Scanning can show subtle row inserts and a small activity pulse on the source card.
- Respect Reduce Motion: use fades and instant layout changes.

Avoid:

- Constant background waves.
- Equalizer bars unless audio is actually playing.
- Spinners for long scans without counts.
- Animated gradients behind library lists.

## Information density

The app must handle a huge NAS library without feeling cramped.

Default phone density:

- Primary tab bar: Library, Playlists, Downloads, Sources, Search.
- Library landing: compact source status strip, continue/recently played, then segmented library modes.
- Library modes: Songs, Albums, Artists, Folders, Videos.
- Track row: artwork or media glyph, title, artist/album or path, trailing duration/cache state, overflow menu.
- Folder row: folder icon, folder name, path/source, child count if known, one-tap Play and Shuffle affordance.
- Source row: source name, protocol/share, status, last scan, speed hint.

Do not waste first-screen space on static explanations. Empty states can teach, but once a source exists the screen should become a working library immediately.

Long NAS paths:

- Middle-truncate paths, not end-truncate.
- Action sheets must allow two-line path labels.
- Detail screens should expose copyable full path and source identity.
- Search results should show matched context: title match, filename match, or folder path match.

## Onboarding and source setup

First launch opens a Library shell with a single strong "Add Source" action. Do not open on a protocol picker.

Setup flow:

1. `Choose Source`: discovered local shares first, manual SMB as secondary, other protocols disabled or marked "coming later" until implemented.
2. `Connect`: host/share/username/password/domain fields, Local Network permission copy, Keychain note.
3. `Test`: connection result, auth status, speed sample, reliability hint.
4. `Choose Roots`: pick one or more folders and classify each as Music, Video, or Mixed.
5. `Start Library`: path-first scan begins; folders become playable immediately while metadata continues.

Visual treatment:

- Use BizarreCRM setup breadcrumb logic, but mobile-native: a compact top progress rail with current step and next step.
- Selected source/root cards use subtle warm fill plus left accent bar, not a full heavy border.
- Test results use operational colors: teal connected, amber slow/limited, rose failed.
- Advanced fields live behind "More connection options".
- The final step should look like a live library coming online, not a success poster.

Critical copy:

- "Folders are playable before scanning finishes."
- "Credentials stay in Keychain on this device."
- "Downloads from SMB continue while the app is open; HTTP/WebDAV can continue in the background."
- "Offline Mode only plays cached media."

## Player screens

### Mini player

Persistent above the tab bar once anything has played.

Layout:

- 44-52 pt height collapsed.
- Left: 36 pt artwork thumbnail or media glyph.
- Center: title and artist/source, one line each.
- Right: play/pause plus optional queue button.
- Bottom edge: 2 pt progress line, `brandPrimary` for played, muted track for remaining.
- Status badge only when useful: caching, offline, compatibility mode, AirPlay route.

Interaction:

- Tap expands to Now Playing.
- Horizontal swipe skips tracks.
- Long press opens queue/actions.
- If source is unreachable and current item is uncached, show a rose disabled state with "Source offline".

### Now Playing audio

This is the emotional screen.

Layout:

- Warm graphite background with artwork-derived tint.
- Album art large, stable, and inspectable. Do not crop covers aggressively.
- Title/artist/album below art, centered or leading based on available width.
- Primary controls: previous, 64 pt play/pause, next.
- Secondary controls: shuffle, repeat, queue, route, sleep timer if added later.
- Scrubber uses monospaced elapsed/duration.
- Source/cache chip row: `NAS name`, `Cached`, `Streaming`, `Compatibility`, `Offline`.

Player states:

- Streaming from NAS: teal source chip, optional small buffer indicator.
- Cached playback: success chip, no network anxiety.
- Downloading current queue: progress chip with count.
- Missing source: rose chip and disabled transport until cached item or source returns.
- Codec fallback: amber chip "Compatibility mode" with details in sheet.

### Video player

Video must prioritize content.

- Use black playback background.
- Chrome appears on tap and fades quickly.
- Keep graphite/cream controls, not album-art tint.
- Show source/cache state in a compact top overlay.
- Video library rows can share the same media identity model but should use poster thumbnails or filename cards.

## Library screens

### Library home

First usable screen:

- Top chrome: title "Library", search affordance, source health button.
- Source status strip: connected count, offline count, active scan/download.
- Continue row: current/last played, not a marketing hero.
- Segmented mode control: Songs, Albums, Artists, Folders, Videos.
- Content starts immediately below; no empty decorative hero once media exists.

### Songs

- Dense list.
- Sort controls: Title, Artist, Album, Recently Added, Source Path.
- Filters: All, Cached, Remote, Missing, Video hidden.
- Row menu: Play Next, Add to Queue, Add to Playlist, Download, Reveal in Folder, Info.

### Albums and artists

- Album grid should be artwork-forward, 2 columns phone portrait, 3 in larger phone/iPad compact column, more on iPad.
- Album cell: art, album title, artist, cache/offline mini badge.
- Unknown album art uses generated warm placeholder, not blank gray.
- Artist detail opens with top songs, albums, folders, and offline availability.

### Folders

This is the wedge and must be obvious.

Folder header:

- Path breadcrumb, source status, scan status.
- Primary buttons: Play, Shuffle.
- Secondary menu: Play Recursively, Shuffle Recursively, Add Recursively to Queue, Download Recursively, Save as Live Playlist.

Folder rows:

- Current-folder play should not wait for subtree traversal.
- Recursive action shows progressive queue count: "127 found so far".
- If a folder is partially indexed, show "Scanning" with teal progress.
- If source is offline, show cached children as playable and remote-only children dimmed.

### Playlists

- App playlists can mix tracks, folders, and live recursive folder references.
- Live folder playlist cells need a loop/folder badge and source health state.
- Imported M3U playlists should show repair warnings inline when paths do not resolve.
- Playlist header uses artwork collage only if it can be built quickly; otherwise use graphite placeholder.

## Downloads and offline

Downloads is not just a queue. It is offline confidence.

Top area:

- Storage budget ring or bar.
- Offline Mode toggle.
- Active transfers summary.
- "Playable offline" count.

Download pack cards:

- Manual downloads, pinned folders, pinned playlists, smart packs, queue prefetch.
- Show required-by reason: Manual, Playlist, Folder, Smart Pack, Next Up.
- Show freshness: Verified, Stale, Waiting for source, Failed.
- Use progress bars with exact counts and byte totals when known.

Offline state model:

| State | Color | UI |
| --- | --- | --- |
| `cached` | success | Check icon, playable. |
| `downloading` | teal | Progress, bytes/count, cancel action. |
| `queued` | textSecondary | Clock icon, reorder/cancel. |
| `prefetched` | brandPrimary soft | Small lightning/cache chip, can evict. |
| `stale` | warning | Playable but needs refresh. |
| `remoteOnly` | textTertiary | Normal when online, dim when offline. |
| `missingSource` | error | Disabled unless cached; repair action. |
| `failed` | error | Retry plus error reason. |

Offline Mode:

- Global toggle is visible in Downloads and in Library filter menus.
- Default offline view keeps library context but dims remote-only items.
- Provide "Playable only" as a filter, not as the only mode.
- Never show a row as playable if it will fail because the cache is absent.

## Source and diagnostics screens

Sources should feel like library roots, not mounted drives.

Source card:

- Name and protocol/share.
- Reachability: Online, Asleep, Auth failed, Local Network blocked, VPN/captive issue.
- Last scan, next scan/manual rescan, indexed items, failed items.
- Speed sample: read speed and recommendation: Stream OK, Pre-cache recommended, Offline only.
- Root folders with Music/Video/Mixed tags.
- Repair path and credential update actions.

Diagnostics:

- Keep details terse but copyable.
- Use redacted paths and credentials in export.
- Present failures in human language first, technical details second.

## Components

### Primary button

- Fill: `brandPrimary`.
- Text/icon: `onBrandPrimary`.
- Height: 44-48 pt.
- Radius: 8 pt, capsule only for compact pills.
- Use for one main action per screen: Add Source, Play, Start Scan, Download.

### Secondary button

- Fill: `surfaceRaised`.
- Border: `borderSubtle`.
- Text: `textPrimary`.
- Use for Shuffle, Test Again, Browse, Repair.

### Status pills

- Height: 24-28 pt.
- Icon + short label.
- Filled softly, not loud.
- Examples: Connected, Cached, Streaming, Offline, Slow, Missing.

### Option cards

- Solid card background.
- Left accent bar for selected state.
- Subtle warm selected fill: dark `rgba(253,238,208,0.08)`, light `rgba(166,109,31,0.08)`.
- Do not change card size on selection.

### Menus and sheets

- Menus must show long folder actions clearly.
- Destructive actions use rose icon/text and confirmation when data can be lost.
- Sheets use `surfaceRaised`, top grabber, and sticky action footer for setup.

## Accessibility

- All controls meet 44 pt tap target.
- Do not rely on color for offline/cache/error states.
- VoiceOver labels should include source/cache state for media rows.
- Large Content Viewer should work for icon-only controls.
- Reduce Transparency replaces glass chrome with `surfaceRaised`.
- Reduce Motion removes matched-geometry expansion and animated progress flourishes.
- High contrast increases borders and uses solid fills for status pills.

## Anti-patterns

Do not build:

- A first-run protocol picker with no library context.
- A blue-gray file manager skin.
- Purple gradients, beige full-screen washes, or one-hue theme drift.
- Album art blurred so much that it becomes muddy wallpaper.
- Glass list rows on every item.
- Cards nested inside cards.
- Heavy caramel borders around large panels.
- Hidden recursive folder playback.
- A downloads screen that is only a transfer queue.
- Offline rows that look playable but fail.
- Status indicated by color alone.
- Decorative empty-state illustrations that push real controls below the fold.
- Marketing copy on the first screen once a library exists.

## Build priorities

1. Tokenize the palette and typography before screen work.
2. Build Library, Folder, Mini Player, Now Playing, Source Setup, and Downloads with real state placeholders.
3. Verify dark mode first, then light mode.
4. Test with ugly data: long NAS paths, missing artwork, 10k-track folders, slow SMB, offline source.
5. Take screenshots on small phone, large phone, and iPad before adding more visual polish.
