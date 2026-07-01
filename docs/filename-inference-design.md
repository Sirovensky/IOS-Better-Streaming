# Per-Folder Filename Metadata Inference — Design

Designed for the "Эпидемия untagged / Artist could be after the title" problem.
NOT yet implemented — it touches the scan hot path and must be validated against
the real NAS with a rescan. Implement when a tappable device/sim is available.

## Goal
When a file has no embedded tags, infer `artist`/`title`/`album` by detecting the
*folder's* dominant naming pattern across all its audio files, applying it
consistently with a confidence score, and degrading to safe folder-derived
defaults rather than corrupting data. **Embedded tags always win.**

## Grounding evidence (live DB, 860 rows)
Layouts seen in single folders:
- `NN - Artist - Title` (`08 - Эпидемия - В этом сне.m4a`) — slot 0 after NN is the constant artist.
- `Artist - NN - Title` (`Avantasia - 02 - Reach Out For The Light.flac`).
- `Artist - Album - NN - Title` (`Amaranthe - Helix - 01 - The Score.flac`).
- `NN Title` (`02 No Return.flac`) — artist comes from the folder.
- bare `Artist - Title` (`Эмма М - Beautiful life.mp3`).
- Compilation: artist **varies every file** ⇒ Various Artists.
- Mojibake folders (`Full Kaidalov MP3/…`, `09-� à¤ă¤ .mp3`) — detect and leave as-is.

## Stage 0 — Per-folder pre-pass (new)
Runs once per directory before building tracks (needs the whole folder's names).
Tokenize each audio file:
- Strip extension; strip a *leading* `NN`, `NN.`, `NN -`, `NN_`, `(NN)`, disc-track `D-NN`/`D.NN` (extend `parseTrack` for disc + `(NN)`/`D-NN`). Capture a bracketed leader `[Artist]` separately.
- Pick the folder's dominant separator by counting: prefer `" - "`, then `" – "`, then `" — "`. Underscore only when no spaced dash exists in the folder AND `_` is frequent. Hyphen without surrounding spaces is NEVER a separator (protects `AC-DC`, `Jay-Z`).
- Split the stem on the chosen separator into trimmed `fields`.

## Stage 1 — Field count + slot roles
`modalFieldCount` = most common `fields.count` among non-garbage files. Only modal-count files infer roles. Per slot, classify across files:
- **CONSTANT** (same value ≥~80%): non-numeric ⇒ **album-artist**.
- **VARYING** (distinct most files): non-numeric ⇒ **title**.
- **NUMERIC** (1–3 digit ints ≥80%) ⇒ in-name track number.
- **ALBUM-MATCH**: constant slot == / prefix of album folder name ⇒ album.
- **FOLDER-MATCH**: constant slot == / prefix of folder or grandparent ⇒ confirms artist.

Role table (after NN strip):

| fields | roles |
|---|---|
| 1 | `[title]` (artist from folder) |
| 2, slot0 CONSTANT, slot1 VARYING | `[artist, title]` |
| 2, slot0 VARYING, slot1 CONSTANT | `[title, artist]` (Title-Artist) |
| 2, both varying | `[artist, title]` only if slot0 name-like; else `[title]`+folder artist |
| 3 with numeric slot | drop numeric → 2-field rules |
| 3, CONSTANT + ALBUM-MATCH + VARYING | `[artist, album, title]` |

**Core rule:** in a 2-field layout, the **constant slot is the artist regardless
of position** (fixes `Title - Artist`). Only when neither is decisively constant
fall back to positional `Artist - Title` and lower confidence.

**Name-likeness tie-break:** artist-like = shorter, no `(remix)/(feat.)/(live)`
qualifier, no sentence punctuation, matches folder/grandparent name.

## Stage 2 — Confidence
```
base 0
+0.35 clear CONSTANT artist slot (scaled by constancy ratio)
+0.25 files match the modal layout
+0.20 constant artist slot matches folder/grandparent
+0.15 album-match slot confirmed
+0.10 consistent numeric/track slot
-0.50 garbage folder
-0.30 modal layout covers <60% of files
```
Clamp [0,1]. Thresholds:
- **≥0.75 HIGH:** apply inferred artist + title.
- **0.45–0.75 MEDIUM:** apply inferred *title* only; artist from folder fallback.
- **<0.45 LOW:** no split; title = cleaned stem, artist = folder fallback.

## Stage 3 — Fallback ladder (never overwrite embedded)
- **Title:** embedded → HIGH-conf pattern title → cleaned stem → raw name.
- **Artist:** embedded → HIGH-conf pattern artist → Various-Artists guard → `fallbackArtist` (parent-of-album) → "Unknown Artist".
- **Album:** embedded → cleaned album-folder name (strip `(YYYY)`/`YYYY -`/`[FLAC]`, collapse disc subfolders via `MetadataGrouping.albumFolderComponents`) → sourceName.
- **Track/disc:** embedded → numeric name slot → leading-NN.

## Stage 4 — Edge cases
- `Title - Artist` → constant-slot rule. ✓
- `Artist - Album - Title(- NN)` → 3-field table + album-match. ✓
- `NN. Title`/`NN - Title` → NN consumed by parseTrack → 1 field → title only. ✓
- `AC-DC`, `Jay-Z` → spaced-dash-only separator. ✓
- Featured artists → kept whole; `MetadataGrouping.creditedArtists` splits downstream — do NOT pre-split feat. ✓
- Various Artists → artist slot varies + one album folder → flag; per-file artist from name at HIGH conf else folder; `albumDisplayArtist` renders "Various Artists". ✓
- Classical → treat constant slot as artist (often performer/orchestra); leave title intact. Known limitation.
- Mojibake → `isGarbage` if high ratio of U+FFFD / C1 controls / symbols→letters; >40% garbage files ⇒ LOW confidence, no splitting.

## Where it slots in
Scan loop (`LibraryService.scan`, per-directory before the file loop): build one
`FolderPattern` from the directory's audio file names, pass into
`track(fromEntry:)` → `resolvedTrackMetadata`. Mirror in `scanLocal` (group URLs
by parent dir).

New `nonisolated static` helpers (no deps):
```swift
struct FolderPattern: Sendable {
    var separator: String?
    var roles: [SlotRole]            // by slot
    var modalFieldCount: Int
    var confidence: Double
    var isVariousArtists: Bool
    var isGarbageFolder: Bool
}
enum SlotRole { case artist, title, album, trackNumber, ignore }

static func inferFolderPattern(fileNames: [String], folderName: String?, parentFolderName: String?) -> FolderPattern
static func applyPattern(_ p: FolderPattern, toStem stem: String) -> (artist: String?, title: String?, album: String?, trackNumber: Int?, discNumber: Int?)
static func looksLikeGarbage(_ s: String) -> Bool
```
Modify `resolvedTrackMetadata` to take `folderPattern` and prefer `applyPattern`
over the unconditional `splitArtistTitle` (keep `splitArtistTitle` as the
LOW-confidence single-file fallback). Extend `parseTrack` for disc + `(NN)`/`D-NN`.
Output stays plain `artist`/`album` strings → `Track` init + `MetadataGrouping`
unchanged. Do NOT pre-split feat. credits in the inferrer.
