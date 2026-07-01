# Format Playback Architecture

Date: 2026-06-28

## Goal

Support the widest practical set of NAS music and video files without turning the MVP into a codec project.

The app should make common personal-library formats feel native first: MP3, AAC, ALAC, FLAC, WAV, AIFF, MP4, M4V, and MOV. It should then add a compatibility path for formats Apple does not handle well or at all: MKV, AVI, WebM, Ogg/Opus/Vorbis, older MPEG/Xvid/DivX-style files, and subtitle-heavy videos.

The product promise should be staged:

- MVP: reliable music-first playback, offline cache, background audio, AirPlay where system-supported, and common MP4/MOV video.
- Broad-format beta: compatibility mode for MKV/AVI/WebM/Opus/Vorbis and richer subtitle handling.
- Later: deeper edge-codec work, advanced subtitle styling, and optional transcoding only if user demand justifies it.

## Decisions

1. Use `AVPlayer` and `AVQueuePlayer` as the default playback engine.
2. Add `VLCKit` as a second renderer only after the AVPlayer/cache/queue path is stable and the licensing/build gate is passed.
3. Do not build or ship a custom decoder for MVP.
4. Do not add FFmpeg, mpv, or GStreamer directly for MVP.
5. Do not hand `smb://` credentials directly to a renderer. Playback should go through local cached files or the app's loopback range proxy.
6. Use cache-first playback for the earliest MVP slice.
7. Use a local loopback HTTP range proxy as the first remote-streaming implementation.
8. Keep `AVAssetResourceLoader` as a fallback strategy, not the default.
9. Probe format support per device, OS version, renderer version, and file, then cache the result.
10. Treat extension-based support tables as hints only. The final decision is made by renderer probing and real playback tests.

## Why AVPlayer First

`AVPlayer` is the right default because it buys the app the platform behavior users expect:

- Background audio with `AVAudioSession` and the audio background mode.
- Lock Screen, Control Center, Now Playing metadata, and remote commands.
- AirPlay route support.
- Picture in Picture through AVKit for video.
- Lower power use through hardware decode.
- HDR handling for supported files and devices.
- Better App Store and maintenance risk than bundling a full codec stack on day one.

The tradeoff is format reach. AVPlayer is strongest with Apple-native containers and codecs, not with arbitrary NAS files. That is acceptable for MVP if the UI is honest: unsupported files should be visible, diagnosable, and eligible for future compatibility mode.

## Why VLCKit Second

`VLCKit` is the pragmatic compatibility backend. It wraps libVLC, which is built for broad container and codec support. It is the best fit for:

- MKV files, especially with multiple audio/subtitle tracks.
- AVI and older MPEG-4 Part 2/Xvid/DivX-era files.
- WebM, VP8, VP9, AV1-in-WebM, Opus, Vorbis, and Ogg containers.
- Subtitle-heavy files, especially ASS/SSA and sidecar subtitles.
- Audio formats AVPlayer does not support consistently, such as Opus and Vorbis.

It should not be the default renderer because it carries real costs:

- LGPL compliance and module-audit work.
- Larger binary size.
- More complex build and release process.
- Weaker system integration for AirPlay, PiP, background behavior, HDR, Now Playing, and power use.
- More App Store review surface.

Use it as "Compatibility Mode", not as the main player.

## Rejected MVP Options

| Option | Decision | Reason |
| --- | --- | --- |
| FFmpeg/libav directly | Do not use in MVP | Powerful but high build, licensing, patent, binary-size, and renderer-integration cost. It also does not give us AirPlay/PiP/Now Playing by itself. |
| mpv | Do not use | Great desktop player core, but GPL and renderer integration make it a poor iOS MVP dependency. |
| GStreamer | Do not use in MVP | Broad and modular, but heavy for iOS and brings plugin/licensing complexity similar to solving a codec platform ourselves. |
| Server-side transcoding | Do not require | This is a NAS/local-first app. Requiring a server component weakens the core product. Consider optional helper/server features later. |
| Full-file download before every play | Use only as early fallback | Reliable but too slow for large libraries and videos. MVP may start cache-first, but streaming must follow quickly. |

## Format Support Tiers

These tiers describe expected handling, not guarantees. Real support must be probed.

| Tier | Formats | Renderer | Product behavior |
| --- | --- | --- | --- |
| Native MVP audio | MP3, AAC/M4A, ALAC/M4A, FLAC, WAV, AIFF | AVPlayer/AVQueuePlayer | Play from cache first, then loopback stream. Background audio required. |
| Native MVP video | MP4, M4V, MOV with H.264, HEVC, supported AAC/ALAC/AC-3/E-AC-3 audio | AVPlayer | Play with AVKit, PiP, AirPlay, resume, and HDR where supported. |
| Device-dependent Apple path | ProRes, AV1, Dolby Vision/HDR10/HLG, high-bitrate HEVC, multi-channel audio | AVPlayer if probe succeeds | Mark capability per device/OS. Do not promise globally. |
| Compatibility audio | Opus, Vorbis, Ogg, WMA, uncommon FLAC/WAV variants | VLCKit | Play through compatibility renderer after legal/build gate. |
| Compatibility video | MKV, AVI, WebM, MPEG-TS/M2TS, older MPEG, VP8/VP9/AV1 WebM, Xvid/DivX-style files | VLCKit | Play through compatibility renderer. AVPlayer can still win if probe succeeds. |
| Subtitle-heavy video | MKV with ASS/SSA/PGS/VobSub, external SRT/ASS | VLCKit preferred | Basic SRT/WebVTT overlay can work with AVPlayer later; complex styling goes to VLCKit. |
| Unsupported/deferred | DRM-protected media, DVD/Blu-ray menus, ISO images, encrypted discs, obscure raw camera formats | None for MVP | Show clear unsupported reason and keep file indexed. |

## Playback Core Shape

The app should expose one playback model to the rest of the product.

```swift
enum PlaybackRendererKind {
    case avFoundation
    case vlcCompatibility
}

struct PlaybackCandidate {
    let itemID: MediaItemID
    let renderer: PlaybackRendererKind
    let source: PlaybackSource
    let containerHint: String?
    let audioCodecs: [String]
    let videoCodecs: [String]
    let subtitleTracks: [SubtitleTrack]
    let supportsBackgroundAudio: Bool
    let supportsAirPlay: Bool
    let supportsPiP: Bool
    let supportsHDR: Bool
    let limitations: [PlaybackLimitation]
}

protocol PlaybackRenderer {
    var kind: PlaybackRendererKind { get }
    func probe(_ source: PlaybackSource) async -> ProbeResult
    func prepare(_ candidate: PlaybackCandidate) async throws
    func play() async
    func pause() async
    func seek(to time: CMTime) async throws
    func selectAudioTrack(_ id: TrackID?) async throws
    func selectSubtitleTrack(_ id: TrackID?) async throws
}
```

`PlaybackCore` owns queue semantics, repeat/shuffle, now playing state, route changes, interruptions, progress persistence, and renderer selection. Renderers should not own the app queue. This keeps AVPlayer and VLCKit interchangeable at item boundaries.

## Renderer Selection

Selection should be deterministic:

1. If the file is already fully cached and the AV probe succeeds, use AVPlayer.
2. If the file is remote and the AV probe succeeds through the loopback URL, use AVPlayer.
3. If AVPlayer fails and VLCKit is available, use VLCKit compatibility mode.
4. If the file is remote and compatibility mode cannot stream it reliably, pre-cache the file or the required opening range, then start VLCKit.
5. If both renderers fail, mark the item unsupported with the renderer errors and a user-readable reason.

Do not switch renderers mid-playback except after a hard failure and an explicit restart of that item. Renderer changes affect track selection, subtitles, Now Playing, and progress reporting.

## Probe Strategy

Probing must be progressive and cheap during indexing.

### Index-Time Probe

During scans, store only cheap hints:

- Extension.
- Path-derived container hint.
- Size and modified time.
- MIME type when the protocol provides one.
- Whether the source supports byte-range reads.
- Sidecar subtitle candidates in the same folder.

Do not run expensive renderer probes over an entire 50k-file library during initial scan.

### Visible-Item Probe

When a file appears in a detail view, search result, or video list, run a bounded probe:

- Check cached `PlaybackCapability` first.
- For likely AV-native files, create an `AVURLAsset` from a cached file or loopback URL.
- Async-load playability, duration, tracks, protected-content state, and basic metadata with a timeout.
- For likely compatibility files, only run VLCKit probing if the compatibility module is installed and the user is near playback.

### Playback-Time Probe

Before play, produce a final `PlaybackCandidate`:

- Revalidate file size and modified time if remote.
- Prefer an existing complete cache file.
- Otherwise create a signed loopback URL for the range proxy.
- Run the selected renderer probe with a short timeout.
- Store success/failure with enough detail for diagnostics.

### Capability Cache

Persist probe results with these keys:

```text
remote_item_id
content_signature: size + modified_at + optional remote_file_id + first/last chunk hash when available
device_model
os_version
app_version
renderer_kind
renderer_version
probe_status
container
audio_codecs
video_codecs
subtitle_formats
duration
hdr_format
failure_code
last_verified_at
```

Invalidate probe results when the file signature changes, app renderer version changes, OS major version changes, or the user installs/enables compatibility mode.

## Streaming and Cache Requirements

### Playback Sources

Every renderer gets one of these source types:

```swift
enum PlaybackSource {
    case localFile(URL)
    case loopbackHTTP(URL, token: String)
}
```

Avoid giving renderers direct SMB/SFTP/WebDAV credentials. The app's source layer should stay responsible for authentication, retries, diagnostics, and caching.

### Loopback Range Proxy

Use a local HTTP server bound only to loopback, with a random port and per-item tokenized URLs.

Requirements:

- Bind to `127.0.0.1` and `::1` only.
- Never expose remote credentials in URLs, logs, or error messages.
- Support `HEAD`.
- Support `GET` with `Range`.
- Return correct `200`, `206`, and `416` responses.
- Return stable `Content-Length`, `Content-Range`, `Accept-Ranges`, `Content-Type`, `ETag`, and `Last-Modified` where known.
- Handle multiple overlapping range requests.
- Apply backpressure and cancellation when the renderer seeks.
- Retry transient remote-read failures with bounded attempts.
- Serve already-cached chunks from disk before remote reads.
- Emit structured diagnostics without paths or credentials unless the user exports an explicit redacted debug bundle.

This proxy is preferred over `AVAssetResourceLoader` for the first streaming implementation because it works with both AVPlayer and VLCKit, is easy to inspect with normal HTTP tooling, and keeps one streaming path for audio and video.

Keep `AVAssetResourceLoader` behind the same `PlaybackSourceFactory` interface as a fallback if the loopback server creates App Store, ATS, AirPlay, or seek behavior problems.

### Cache Layers

Use two cache layers:

| Layer | Purpose | Durability |
| --- | --- | --- |
| Playback byte cache | Current item, seeks, and next queue window | Evictable, chunk-indexed |
| Offline cache | User-pinned files, folders, playlists, smart packs | Durable until user removes or quota policy evicts unpinned items |

Chunk records should include:

```text
cache_item_id
remote_item_id
byte_range
local_chunk_url
bytes_written
checksum_if_available
state: pending | ready | failed | stale
last_accessed_at
```

For audio queues, prefetch the current track and the next 1-3 tracks. For video, prefetch based on bitrate estimate and source speed test. Do not prefetch a full 4K movie by default.

Cached media needed for lock-screen playback should use a file-protection class that remains readable after first unlock, such as complete-until-first-user-authentication. Do not use complete protection for actively playable cache files.

## Remote Protocol Requirements

The playback layer depends on `RemoteFileSystem` supporting byte ranges and cancellation.

```swift
protocol RemoteFileSystem {
    func list(_ directory: RemotePath) async throws -> [RemoteEntry]
    func stat(_ path: RemotePath) async throws -> RemoteMetadata
    func read(_ path: RemotePath, range: Range<Int64>) async throws -> Data
    func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink) async throws
}
```

Playback-specific requirements:

- `read` must be cancellable.
- `read` must report authorization failures, missing files, stale handles, timeout, server disconnect, and unsupported range separately.
- `stat` must be cheap enough to run before playback.
- Sources that cannot provide ranges are cache-before-play for video and large audio.
- HTTP/WebDAV should use native HTTP range requests and `URLSession` where possible.
- SMB/SFTP/FTP use app-managed range reads and app-managed downloads.

## Subtitles

Subtitle handling should be useful but not block the MVP.

### MVP

- Discover sidecar subtitle files by basename during scan: `.srt`, `.vtt`, `.ass`, `.ssa`.
- Store subtitle candidates in the media database.
- For AVPlayer video, rely first on embedded subtitles/captions AVFoundation exposes.
- Show subtitle tracks in the UI only when the renderer reports selectable tracks.

### First Video Upgrade

- Implement a simple app overlay for external `.srt` and `.vtt` with AVPlayer.
- Use player time observations to display cues.
- Support text encoding detection for UTF-8 and UTF-16.
- Support subtitle offset adjustment.
- Do not attempt full ASS/SSA styling in the AVPlayer overlay.

### Compatibility Mode

Use VLCKit for:

- ASS/SSA styling.
- PGS/VobSub-style image subtitles where supported.
- MKV subtitle track selection.
- Multiple external subtitle files.

The UI should label limitations plainly: "Basic subtitles" for AVPlayer overlay and "Compatibility subtitles" for VLCKit.

## HDR and Video Quality

Use AVPlayer for HDR whenever possible.

Rules:

- Prefer AVPlayer for Dolby Vision, HDR10, HDR10+, HLG, HEVC Main10, ProRes, and high-bitrate MP4/MOV files when probe succeeds.
- Query device support at runtime and store HDR capability in the probe result.
- Do not custom-render HDR video in MVP.
- Do not send HDR files through VLCKit by default if AVPlayer can play them.
- If compatibility mode plays an HDR file, treat HDR preservation as best-effort and record whether output is HDR or tone-mapped.
- Keep the video surface in AVKit for MVP to preserve PiP and system controls.

HDR support differs by device, codec, profile, container, and route. The UI should avoid global claims like "HDR supported" and instead show support on the item or route when known.

## AirPlay, PiP, and Background Audio

### AVPlayer Path

Required for MVP:

- `AVAudioSession` category `.playback`.
- Audio background mode.
- Lock Screen and Control Center metadata through Now Playing.
- Remote command handling for play, pause, next, previous, seek, and skip intervals.
- Route-change handling.
- Interruption handling.
- AVKit PiP for video.
- AirPlay route support where AVPlayer supports the media and route.

### VLCKit Path

Compatibility mode should not be allowed to weaken core product behavior silently.

Initial VLCKit expectations:

- Background audio: app-managed session and Now Playing updates, tested per format.
- AirPlay: best-effort only unless validated.
- PiP: not promised initially.
- HDR: not promised initially.
- Lock-screen controls: app-owned queue commands still work, but renderer-specific seeking must be tested.

If a file needs VLCKit, show limitations in the item diagnostics or playback options.

## Fallback Behavior

Failures should produce stable, user-readable states:

| Failure | User state | Next action |
| --- | --- | --- |
| AVPlayer cannot open container | Needs compatibility mode | Try VLCKit if available. |
| AVPlayer opens but decoder fails | Needs compatibility mode | Try VLCKit and record codec failure. |
| Remote range reads too slow | Buffering or pre-cache recommended | Offer "Cache before playing" and adjust prefetch. |
| Source lacks range support | Cache required | Download before playback. |
| File moved or changed | File missing or changed | Offer source repair/rescan. |
| DRM/protected content | Unsupported protected file | Do not attempt bypass. |
| VLCKit missing in MVP | Not playable yet | Keep indexed and explain compatibility support is not installed. |

Do not hide unsupported files by default. Users need to see why a NAS file did not play.

## Licensing and App Store Risk

### AVFoundation

AVFoundation is the low-risk path. It uses Apple frameworks and should be the only playback dependency required for MVP submission.

### VLCKit

Before VLCKit lands in the shipping target, complete this gate:

- Confirm exact VLCKit version and license.
- Audit bundled VLC modules and disable/remove GPL-only or legally risky modules.
- Confirm LGPL obligations with counsel or a qualified open-source review.
- Ship attribution and license notices in Settings.
- Publish or link to corresponding VLCKit source and any modifications.
- Prefer dynamic linking where practical for LGPL compliance.
- Verify App Store archive, symbol stripping, bitcode status if relevant, and binary size.
- Run TestFlight playback on physical devices before relying on compatibility mode.
- Do not download codec plugins after review.
- Do not include DVD/Blu-ray decryption or DRM-circumvention modules.

VideoLAN documents libVLC redistribution under LGPL terms, with the warning that some modules may be GPL. Treat module audit as mandatory, not paperwork.

### Codec Patent Risk

Codec patents are separate from open-source copyright licenses. Hardware-decoded Apple formats are safest. Bundled software decoders for proprietary codecs can create patent exposure depending on jurisdiction and distribution model.

Practical rule: keep MVP on AVFoundation, and make compatibility mode a conscious legal/product decision before shipping.

### App Store Review Risk

Expected review-sensitive areas:

- Local Network permission must clearly explain NAS/media-server discovery and playback.
- Background modes must be limited to audio/AirPlay/PiP behavior the app actually provides.
- Long SMB/SFTP/FTP downloads cannot pretend to be guaranteed background downloads.
- HTTP/WebDAV background downloads should use `URLSession` background transfers.
- Local loopback server must bind only to loopback and not expose a general-purpose file server.
- Diagnostics must redact credentials, tokens, server paths where needed, and personally identifying filenames unless the user explicitly exports them.
- No dynamic code, downloaded codecs, or hidden plugin systems.

## Test Media Matrix

Keep a versioned local test library outside git, with generated checksums and a manifest checked into tests later.

### Audio

| Case | Container/codec | Expected MVP result | Expected broad result |
| --- | --- | --- | --- |
| MP3 CBR | `.mp3` / MP3 / ID3v2.3 | AVPlayer | AVPlayer |
| MP3 VBR | `.mp3` / MP3 VBR / ID3v2.4 | AVPlayer | AVPlayer |
| AAC | `.m4a` / AAC-LC | AVPlayer | AVPlayer |
| HE-AAC | `.m4a` / HE-AAC | AVPlayer if probe succeeds | AVPlayer if probe succeeds |
| ALAC | `.m4a` / ALAC | AVPlayer | AVPlayer |
| FLAC 16-bit | `.flac` / FLAC 44.1k | AVPlayer if probe succeeds | AVPlayer or VLCKit |
| FLAC hi-res | `.flac` / FLAC 24/96 | AVPlayer if probe succeeds | AVPlayer or VLCKit |
| WAV PCM | `.wav` / PCM 16/44.1 | AVPlayer | AVPlayer |
| AIFF PCM | `.aiff` / PCM | AVPlayer | AVPlayer |
| Opus | `.opus` or `.ogg` / Opus | Not playable yet | VLCKit |
| Vorbis | `.ogg` / Vorbis | Not playable yet | VLCKit |
| WMA | `.wma` / WMA | Not playable yet | VLCKit if supported |
| Audiobook | `.m4b` / AAC chapters | AVPlayer, chapter support later | AVPlayer |

### Video

| Case | Container/codec | Expected MVP result | Expected broad result |
| --- | --- | --- | --- |
| MP4 H.264 | `.mp4` / H.264 + AAC | AVPlayer | AVPlayer |
| M4V H.264 AC-3 | `.m4v` / H.264 + AC-3 + text subs | AVPlayer if probe succeeds | AVPlayer |
| MOV HEVC | `.mov` / HEVC + AAC | AVPlayer if device supports | AVPlayer |
| MP4 HEVC Main10 HDR10 | `.mp4` / HEVC 10-bit HDR10 | AVPlayer if device/route supports | AVPlayer |
| Dolby Vision | `.mp4`/`.mov` / Dolby Vision | AVPlayer if device supports | AVPlayer |
| ProRes | `.mov` / ProRes | AVPlayer if device supports | AVPlayer |
| AV1 MP4 | `.mp4` / AV1 + AAC/Opus | Device-dependent AVPlayer probe | AVPlayer or VLCKit |
| MKV H.264 | `.mkv` / H.264 + AAC | Not playable yet unless AV probe succeeds | VLCKit |
| MKV HEVC 10-bit | `.mkv` / HEVC + multiple audio | Not playable yet | VLCKit |
| MKV ASS subs | `.mkv` / H.264 + ASS | Not playable yet | VLCKit |
| AVI Xvid | `.avi` / MPEG-4 ASP + MP3 | Not playable yet | VLCKit |
| WebM VP9 | `.webm` / VP9 + Opus | Not playable yet | VLCKit |
| WebM AV1 | `.webm` / AV1 + Opus | Not playable yet | VLCKit if supported |
| MPEG-TS | `.ts` / H.264 + AC-3 | Probe only | VLCKit or AVPlayer if remux/probe succeeds |
| M2TS | `.m2ts` / H.264/HEVC + AC-3 | Not playable yet | VLCKit if supported |

### Subtitles

| Case | Expected MVP result | Expected broad result |
| --- | --- | --- |
| MP4 embedded text subtitle | AVPlayer if exposed | AVPlayer |
| HLS/WebVTT-style subtitle | AVPlayer if exposed | AVPlayer |
| External SRT UTF-8 | Discovered, overlay later | AVPlayer overlay or VLCKit |
| External SRT UTF-16 | Discovered, overlay later | AVPlayer overlay or VLCKit |
| External WebVTT | Discovered, overlay later | AVPlayer overlay |
| MKV ASS/SSA | Not playable yet | VLCKit |
| MKV PGS/VobSub | Not playable yet | VLCKit if supported |
| Subtitle offset | Not MVP | App-level offset control |

### Playback Conditions

Every renderer path must be tested against:

- Fully cached file.
- Remote loopback stream.
- Seek near start, middle, and end.
- Network disconnect during playback.
- Server returns stale file size.
- Source password changes.
- Device locks during playback.
- App goes to background.
- Incoming phone interruption.
- AirPods route change.
- AirPlay route change.
- PiP enter/exit for AVPlayer video.
- Low-storage cache eviction.
- Offline mode with cached file.
- Offline mode with missing remote-only file.

### NAS and Protocol Matrix

Test at least:

- Synology SMB.
- QNAP SMB.
- TrueNAS SMB.
- Windows share.
- macOS file sharing.
- WebDAV over HTTPS.
- Plain HTTP file server with ranges.
- Slow Wi-Fi.
- High-latency VPN.
- Captive/local-network permission denied path.

## Implementation Order

1. Build `PlaybackCore` with the renderer abstraction and AVPlayer renderer only.
2. Implement cache-first AVPlayer audio playback for MP3, AAC/M4A, ALAC/M4A, FLAC, WAV, and AIFF.
3. Add Now Playing, remote commands, interruptions, route changes, and lock-screen continuation.
4. Implement complete-file cache records and quota basics.
5. Build the loopback range proxy and validate MP3, M4A, FLAC, and MP4 seeking through AVPlayer.
6. Add `PlaybackProbeService` and persist `PlaybackCapability`.
7. Add AVPlayer video with AVKit, resume, PiP, AirPlay, and HDR probing.
8. Add sidecar subtitle discovery and database storage.
9. Add basic SRT/WebVTT overlay for AVPlayer video if video usage demands it before VLCKit.
10. Run the VLCKit licensing/build gate.
11. Add VLCKit renderer behind a feature flag.
12. Route MKV, AVI, WebM, Ogg/Opus/Vorbis, and subtitle-heavy files to compatibility mode.
13. Expand the test media matrix before claiming broad format support.

## Builder Checklist

- Keep playback state independent from renderer state.
- Never decide support from extension alone.
- Prefer AVPlayer when both renderers work.
- Prefer cached local file over remote stream when available.
- Use the same loopback proxy for AVPlayer and VLCKit remote playback.
- Keep unsupported files visible and explain why they failed.
- Record renderer errors in diagnostics with redaction.
- Do not add broad-codec dependencies without a license and App Store review.
- Do not promise PiP, AirPlay, HDR, or background behavior for compatibility mode until tested.
- Do not block recursive folder playback on deep media probing.

## References

- Apple AVFoundation: https://developer.apple.com/av-foundation/
- Apple AVPlayer: https://developer.apple.com/documentation/avfoundation/avplayer/
- Apple media playback configuration: https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback
- Apple AVAssetResourceLoader: https://developer.apple.com/documentation/avfoundation/avassetresourceloader
- Apple HDR playback note: https://developer.apple.com/news/?id=rwbholxw
- Apple current-device media examples: https://support.apple.com/en-us/121031
- VLCKit repository/license summary: https://github.com/videolan/vlckit
- VLC legal concerns: https://vlc-user-documentation.readthedocs.io/en/latest/support/faq/legalconcerns.html
