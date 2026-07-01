# Recon and Build Plan

Date: 2026-06-28

## Product thesis

Build the NAS-first media app VLC never became on iOS: a polished music player that also plays video, where SMB/FTP/WebDAV/SFTP files behave like a real library instead of a remote file browser.

The wedge is simple and strong:

- Play any folder recursively, including subfolders.
- Build queues and playlists from remote files without downloading them first.
- Cache or download any track, folder, playlist, album, search result, or "next up" queue.
- Keep the same item identity whether it is remote, cached, moved, renamed, or offline.
- Make the first screen a library and player, not a protocol picker.

The app should not try to out-VLC VLC on codec coverage first. It should beat VLC on daily use: queue control, recursive folder playback, playlist building, offline packs, search, metadata, and low-friction source setup.

## Permanent recon clones

These live under `recon/repos/` and are ignored by git.

| Repo | Current commit | Why it is here |
| --- | --- | --- |
| `vlc-ios` | `13bad2c` | Open iOS/tvOS VLC app architecture, network browsing, VLCKit playback, downloads. |
| `SMBClient` | `66eafaa` | Pure Swift SMB2 client, MIT, no external dependencies. Best first SMB prototype target. |
| `AMSMB2` | `90737c4` | Mature SMB2/3 wrapper over `libsmb2`. Useful fallback, but LGPL dynamic-link constraints matter. |
| `Swiftfin` | `0743086` | Native Swift video client; useful AVPlayer vs VLCKit comparison and player abstraction. |
| `finamp` | `8ac68d0` | Music-player offline/download and queue behavior for a self-hosted library. |

## Competitor findings

VLC is strongest on codec/protocol reach, but its remote-server UX is file-browser first. The iOS code uses a `VLCNetworkServerBrowser` abstraction with protocol adapters for SMB/FTP/SFTP/NFS/UPnP and hands `VLCMedia` lists to playback. Remote "Play All" only uses files in the current folder; proper playlists are mostly tied to the local media library. Relevant local files:

- `recon/repos/vlc-ios/Sources/Network/Server Browsing/Data/Protocols/General/VLCNetworkServerBrowserVLCMedia.m`
- `recon/repos/vlc-ios/Sources/Network/Server Browsing/View Controllers/VLCNetworkServerBrowserViewController.m`
- `recon/repos/vlc-ios/Sources/Network/Download/VLCMediaFileDownloader.m`

MusicStreamer is the clearest music UX target: recursive scanning, metadata/artwork library views, playlists, M3U import/export, offline downloads for songs/albums/playlists/search results, offline-only mode, CarPlay, AirPlay/Chromecast, and multiple libraries. Recent App Store notes also point at practical edge cases we should expect: QNAP read quirks, metadata extraction bugs, persistent queue/history, playlist import details, VoiceOver fast scrolling, and wide popup menus for long NAS paths.

Infuse is the video UX target: broad network protocols, clean share setup, library indexing, metadata, downloads, and built-in speed tests. It is video-first and polished, but not a local-files music player. Its speed-test feature is worth copying because SMB/NFS/WebDAV performance varies dramatically by NAS and network.

Evermusic/Flacbox show expected premium music features: SMB/WebDAV/DLNA/FTP/SFTP/NFS, offline mode, audio cache, M3U playlists, equalizer, gapless/crossfade, lyrics, CarPlay, AirPlay/Chromecast. Evermusic's public docs describe smart preloading and configurable playback cache with AVPlayer/resource-loader style streaming; that validates a cache-plus-streaming approach instead of forcing full downloads.

nPlayer is a feature-dense video/file player: SMB/WebDAV/FTP/SFTP/NFS/UPnP/DLNA, playlist file support, playback speed, resume, AB repeat, subtitles, hardware acceleration. It is not the UX baseline for a friendly music library.

FE File Explorer/Owlfiles are file managers with streaming. Good for transfer/browse expectations, not a music-player model.

## Product position

Remote sources are first-class libraries, not folders you visit once. The app should feel like Apple Music for a personal NAS, with a power-user file browser underneath.

Core positioning:

- "Your NAS music library, finally usable on iPhone."
- Free or fair pricing, no subscription required for the core SMB music experience.
- Music-first, video-capable.
- Local-first privacy: credentials in Keychain, library index on device, no cloud account required.
- Friendly default UI with advanced protocol knobs hidden until needed.

Killer product angles:

- Folder as playlist: every folder can be played, shuffled, repeated, downloaded, or saved as a live playlist.
- Recursive mode is obvious: folder actions include Play Folder, Shuffle Folder, Play Recursively, Shuffle Recursively, Add Recursively to Playlist, Download Recursively.
- Smart offline packs: pin "Gym", "Commute", "Recently Played", "Favorites", or any folder/playlist; the app keeps them downloaded within a storage budget.
- Connection health: show source reachability, last scan, speed sample, and whether remote playback is safe or should pre-cache.
- Repair instead of break: if a NAS path changes, let the user reconnect a missing source/folder and remap items.
- Privacy as UX: no forced account, no telemetry by default, no server component.

## MVP scope

MVP should prove one vertical slice deeply rather than many protocols shallowly.

1. iOS app, iPhone first, iPad layout kept sane.
2. SMB source support first.
3. WebDAV/HTTP second because it can use `URLSession` background transfers cleanly.
4. FTP/SFTP third, then NFS/DLNA after the media model is stable.
5. Local library index: tracks, videos, folders, playlists, artwork, source credential reference, cached-file state.
6. Recursive folder scan with progress, cancellation, pause/resume, and "scan only this subtree".
7. Playback queue with shuffle, repeat all, repeat one, play next, append, reorder, clear, and queue persistence.
8. Remote playlists and local app playlists; playlists can contain files, folders, and dynamic recursive folder references.
9. Cache/download selected files, folders, albums, playlists, search results, and the next queue window.
10. Offline mode that only shows playable cached content while preserving original library context.
11. Background audio, Lock Screen/Control Center metadata, remote commands, interruptions, and route changes.

Defer: Chromecast, Last.fm, tag editor, lyrics, cloud providers, Plex/Jellyfin/Navidrome, CarPlay, tvOS, background source auto-sync, full subtitle management, DLNA casting, social/sharing.

## Non-negotiable user flows

First-run source setup:

1. Add Source.
2. Pick SMB or discover local SMB shares.
3. Enter host/share/credentials.
4. Test connection and show speed/reliability hint.
5. Choose one or more root folders and mark each as Music, Video, or Mixed.
6. Start a fast path scan that makes folders playable immediately while deeper metadata continues in the background.

Folder playback:

1. Open any folder.
2. Tap Play or Shuffle for immediate current-folder playback.
3. Long press or menu for recursive actions.
4. While recursive traversal continues, the queue fills progressively and playback starts as soon as the first playable item is ready.

Playlist creation:

1. Select remote files, folders, or search results.
2. Add to playlist without downloading.
3. Playlist stores stable remote identities plus optional live-folder references.
4. Offline toggle pins the playlist and schedules downloads.

Offline use:

1. App opens with no server reachable.
2. Library stays browsable.
3. Cached items play; missing remote-only items are visible but disabled or filtered by Offline Mode.
4. Downloads resume or reconcile when the source returns.

## Architecture

Use SwiftUI with Swift Concurrency. Target iOS 17+ initially unless App Store reach forces iOS 16.

Core modules:

- `SourceKit`: saved sources, credentials, Keychain storage, Local Network permission copy, connection tests, Bonjour/NetBIOS-style discovery where possible.
- `RemoteFileSystem`: protocol-neutral file API: list, stat, read range, stream/download, search when supported.
- `LibraryIndexer`: recursive traversal, media-type detection, metadata/artwork extraction, duplicate handling, incremental rescan, path repair.
- `MediaStore`: SQLite persistence, probably GRDB; schema should support large libraries, FTS search, scan checkpoints, and queue persistence.
- `PlaybackCore`: audio and video player abstraction, queue, shuffle/repeat, now playing, route changes, interruptions, renderer selection.
- `StreamBridge`: local HTTP range proxy or `AVAssetResourceLoader` implementation that translates AVPlayer byte-range reads into remote file reads.
- `CacheManager`: downloads, partial files, quota, eviction, offline state, path repair after iOS container changes, file-protection policy for lock-screen playback.
- `PlaylistCore`: app playlists with remote item references, live folder playlists, M3U import/export.
- `Diagnostics`: speed tests, failed-read classification, server capability snapshots, user-shareable debug bundle with secrets stripped.

Protocol abstraction should be designed around byte ranges from day one:

```swift
protocol RemoteFileSystem {
    func list(_ directory: RemotePath) async throws -> [RemoteEntry]
    func stat(_ path: RemotePath) async throws -> RemoteMetadata
    func read(_ path: RemotePath, range: Range<Int64>) async throws -> Data
    func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink) async throws
}
```

Data identity:

```text
source_id + share_id + normalized_remote_path + remote_file_id_if_available + size + modified_at
```

Do not use a plain URL string alone; SMB/NAS paths, share names, server aliases, and credentials can change. Keep `remote_file_id_if_available` optional because many protocols will not provide stable inode-like IDs. Treat renames/moves as repairable when size, modified time, duration, and audio fingerprints match.

## Playback choice

Default to AVPlayer/AVQueuePlayer where possible because Apple gives us background audio, AirPlay, PiP, HDR handling, lower power, and system integration. Apple documents AVPlayer for local and remote file-based media and HLS, and AVAudioSession/background modes are the correct path for lock-screen audio.

Add VLCKit as a compatibility backend for unsupported containers/codecs, especially MKV/AVI/Opus/Vorbis/WMA/subtitle-heavy video. Swiftfin's architecture is the model: one app player abstraction, multiple renderers.

For SMB files, AVPlayer cannot directly consume `smb://` through arbitrary libraries. We need one of:

- Local cache file before playback.
- Local loopback HTTP server that supports byte ranges and proxies reads from SMB/SFTP/WebDAV into AVPlayer.
- `AVAssetResourceLoader` with a custom URL scheme and cache-aware range loader.
- VLCKit direct protocol playback for compatibility mode.

MVP playback plan:

1. Cache-first playback for reliability and fast implementation.
2. Add range-based streaming for immediate remote playback.
3. Add queue prefetch: current track plus next 1-3 tracks into a rolling cache.
4. Add VLCKit only after the core library/queue/offline model is working.

Open question: local HTTP proxy vs `AVAssetResourceLoader`. Resource loader avoids loopback server complexity and is validated by apps like Evermusic, but it can be fiddly for video seeks and content-info responses. Local HTTP proxy is more universal and debuggable. Spike both with SMB range reads before committing.

## SMB decision

Prototype with `SMBClient` first:

- Pure Swift, MIT, no binary or LGPL distribution concern.
- Async/await API.
- Supports list shares, list directory, read, download to file, upload, basic file operations.
- Limitation: SMB2 only today; no SMB1, no AFP.

Keep `AMSMB2` as fallback:

- SMB2/3 via `libsmb2`.
- Broader mature file API.
- LGPL means dynamic linking for App Store distribution; verify packaging before shipping.

SMB risk checklist:

- Synology, QNAP, TrueNAS, Windows share, macOS file sharing.
- Guest, username/password, domain/workgroup, non-default port.
- Large directories, deep recursion, Unicode filenames, case-insensitive collisions.
- Sleep/wake and network changes.
- Slow Wi-Fi, VPN, captive networks, and Local Network permission denial.
- SMB signing/encryption performance differences.

## Cache/download model

Do not copy VLC's generic demux-dump approach. Build explicit cache records:

- `remote_item_id`
- `local_file_url`
- `state`: queued, downloading, cached, failed, stale, evicted
- `bytes_total`, `bytes_done`
- `checksum_if_available`
- `required_by`: playlist/folder/manual pin/smart pack/prefetch
- `last_played_at`, `last_verified_at`

Caching has two layers:

- Playback buffer: rolling byte cache used by streaming and prefetch.
- Offline cache: durable pinned files managed by quota and visible to the user.

For HTTP/WebDAV, use `URLSession` background downloads. For SMB/SFTP/FTP, use app-managed downloads with background task continuation where iOS allows it; assume long non-HTTP downloads may pause when suspended. Make this honest in the UI: "continues while app is open" vs "continues in background".

Important iOS detail: choose file protection so cached media can continue playing after the device locks. Do not store credentials in filenames or diagnostic logs.

## Metadata and indexing

Indexing must be progressive:

1. Path index: folders/files become browsable and playable quickly.
2. Basic media probe: extension, size, duration when cheap.
3. Tag extraction: artist/album/title/track/disc/artwork in a throttled queue.
4. Artwork cache: embedded art first, folder art (`cover.jpg`, `folder.jpg`) second, generated placeholders last.
5. FTS search update.

Do not block folder playback on full tag extraction. For large NAS libraries, a complete scan may take hours and should survive app restarts. Store scan checkpoints per source/subtree.

Folder ordering rules matter:

- Natural sort filenames.
- Respect track number and disc number when metadata exists.
- For mixed folders, keep folder hierarchy visible but let recursive playback flatten predictably.
- Offer per-folder sort override later, but default should be boring and correct.

## UX principles

- First screen is Library, not a server browser.
- Source setup should feel like adding a music library, not mounting a network drive.
- A folder row gets one-tap Play and Shuffle, plus a menu for recursive actions.
- Every item shows a clear remote/cached/downloading/offline-missing state.
- Search spans title, artist, album, filename, folder path.
- Long NAS names and paths must not truncate important context in action sheets.
- Errors should be human: "Server asleep", "Password failed", "Wi-Fi blocked local network", "File moved", "Codec needs compatibility mode".
- Advanced protocol knobs are hidden until needed.

Primary tabs:

- Library: Songs, Albums, Artists, Folders, Videos.
- Playlists: app playlists, imported M3U, live folder playlists.
- Downloads: pinned/offline packs, active queue, storage budget.
- Sources: connection status, scan controls, diagnostics.
- Search: global library search, with offline filter.

## First build milestones

0. Technical spike: SMB list/stat/read-range/download, 10k-file recursive scan, AVPlayer cache playback, lock-screen audio, and one range-streaming prototype.
1. Create the iOS project shell with SwiftUI, GRDB, source list, MediaStore schema, and placeholder player.
2. Implement SMB source add/test/list using `SMBClient`, with Keychain credentials and Local Network permission copy.
3. Implement path-first recursive scan into SQLite with progress, cancellation, checkpoints, and FTS by filename/path.
4. Implement library screens: Folders first, then Songs, Albums, Videos, Playlists.
5. Implement queue from remote folder: Play, Shuffle, Play Recursively, Shuffle Recursively, Play Next, Add to Queue.
6. Implement cache download to app storage and offline state for files/folders/playlists.
7. Implement audio queue with AVQueuePlayer, shuffle/repeat, background audio, Now Playing, route changes, and interruption handling.
8. Implement local range-proxy or resource-loader streaming so uncached SMB files can start quickly.
9. Implement metadata extraction/artwork cache and album/artist views.
10. Add video playback with AVPlayer first, then VLCKit compatibility.

## MVP quality bar

The first beta is only credible if these pass:

- Add SMB source and start music playback in under 2 minutes from fresh install.
- Recursive shuffle on a folder with 5k-10k tracks starts before the full tree is scanned.
- Cached audio continues from lock screen.
- Queue survives app restart.
- Offline mode is obvious and never shows a playable item that fails due to missing cache.
- Search stays responsive on a 50k-track library.
- A moved source/folder can be repaired without rebuilding every playlist manually.
- No credential leakage in logs, crash reports, or exported diagnostics.

## Risk register

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| SMB library limits | SMB dialects and NAS quirks can sink reliability. | Spike `SMBClient`; keep `AMSMB2` fallback; test Synology/QNAP/Windows/macOS early. |
| iOS background limits | Non-HTTP downloads may pause when app suspends. | Be explicit in UI; use WebDAV/HTTP background sessions where possible; pin short prefetch windows. |
| AVPlayer custom streaming | Range loaders are easy to get subtly wrong. | Build a focused spike before UI polish; test seeking, interruptions, lock screen, large files. |
| Codec coverage | Users expect VLC-like "plays anything". | AVPlayer first for system polish; VLCKit compatibility after core UX is stable. |
| Large library indexing | NAS libraries can be huge and slow. | Path-first indexing, checkpoints, lazy metadata, cancellation, resumable scans. |
| Licensing | VLCKit/SMB libraries can affect distribution. | Track licenses before dependencies land; prefer MIT/BSD/Apache for MVP. |
| App Store/privacy | Local network and background modes need clear purpose. | Provide clear permission strings; keep features aligned with media playback. |

## Source links

- VLC iOS source: https://github.com/videolan/vlc-ios
- VLC App Store protocol list: https://apps.apple.com/us/app/vlc-media-player/id650377962
- MusicStreamer product: https://www.stratospherix.com/products/musicstreamer/
- MusicStreamer user guide: https://www.stratospherix.com/products/musicstreamer/support/
- MusicStreamer Lite App Store release notes: https://apps.apple.com/us/app/musicstreamer-lite/id1240276145
- Infuse network streaming docs: https://support.firecore.com/hc/en-us/articles/215090977-Streaming-From-a-Mac-PC-or-NAS
- Infuse setup/library docs: https://support.firecore.com/hc/en-us/articles/215090797-Basic-Setup
- Infuse speed test docs: https://support.firecore.com/hc/en-us/articles/7551452226967-Testing-Streaming-Speeds
- nPlayer: https://nplayer.com/
- Evermusic: https://everappz.com/products/evermusic/
- Evermusic FAQ: https://everappz.com/docs/faq/evermusic/
- Evermusic guide/cache notes: https://everappz.com/docs/guide/evermusic/
- Flacbox App Store: https://apps.apple.com/us/app/flacbox-hi-res-music-player/id1097564256
- FE File Explorer: https://www.skyjos.com/fileexplorer/
- Apple media playback config: https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback
- Apple AVPlayer: https://developer.apple.com/documentation/avfoundation/avplayer
- Apple AVAssetResourceLoader: https://developer.apple.com/documentation/avfoundation/avassetresourceloader
- Apple background downloads: https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
- SMBClient: https://github.com/kishikawakatsumi/SMBClient
- AMSMB2: https://github.com/amosavian/AMSMB2
- Swiftfin: https://github.com/jellyfin/swiftfin
- Finamp: https://github.com/unicornsonlsd/finamp
- GRDB: https://github.com/groue/GRDB.swift
