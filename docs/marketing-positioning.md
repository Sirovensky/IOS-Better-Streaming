# Marketing Positioning

Date: 2026-06-28

## Core position

This app is a convenient, privacy-respecting streaming player for personal NAS and local-server media libraries. It is for people who already own their music and video files, keep them on a home server, and want those files to feel like a real iPhone library instead of a remote file browser.

Primary positioning:

> Your NAS music library, finally comfortable on iPhone.

Supporting position:

> A free, open-source, music-first player for personal servers. No ads, no required account, no paywall for core local streaming.

The app should be framed as:

- Personal media first, cloud service second to none.
- Music-first and video-capable.
- Built around folders, playlists, queues, caching, and offline use.
- Designed for NAS, SMB, WebDAV, FTP/SFTP, and local-server workflows.
- Open source, donation-supported, and honest about platform limits.

The app should not be framed as:

- A VLC replacement for every codec on day one.
- A Plex/Jellyfin/Navidrome replacement.
- A piracy app.
- A file manager with playback bolted on.
- A premium lifestyle music service.

## Differentiation

The wedge is daily usability for personal server libraries:

- VLC is broad and dependable, but its remote-source experience is still mostly browse-and-play. This app should make remote folders behave like a library.
- MusicStreamer is the closest music UX benchmark. This app can compete by being open source, transparent, donation-supported, and focused on modern iOS library, queue, and cache behavior.
- Evermusic and Flacbox validate demand for offline local-server music, but they are commercial closed-source apps with many cloud-provider features. This app should be narrower, clearer, and more trust-oriented.
- Infuse is the video UX benchmark, but it is video-first and not trying to be a serious local music player.
- nPlayer is powerful, but feature density is not the desired personality. This app should feel simpler, calmer, and more library-native.

Positioning sentence:

> For people with music and videos on a NAS, this app turns remote folders into a fast, searchable, offline-capable iPhone library without ads, accounts, or a subscription.

## Target personas

### The NAS music owner

Owns a large folder-based music library on Synology, QNAP, TrueNAS, Windows, or macOS file sharing. May have FLAC, ALAC, MP3, AAC, or mixed tags. Wants recursive shuffle, album browsing, search, playlists, and reliable offline packs.

Message:

> Stop browsing your NAS one folder at a time. Play, shuffle, search, queue, and download your personal music library like it belongs on your phone.

Most important features:

- Recursive folder playback.
- Persistent queue.
- Album, artist, song, folder, and search views.
- Offline packs for folders and playlists.
- Clear cached, remote, downloading, and offline-missing states.

### The privacy-conscious self-hoster

Avoids forced cloud accounts, subscriptions, telemetry, and ads. Wants software that works on their own network and can be audited.

Message:

> Your files stay on your server. Your library index stays on your device. The app is open source and funded by optional support, not tracking or ads.

Most important features:

- No required account.
- Local index.
- Keychain credential storage.
- No ads.
- No default telemetry.
- Clear diagnostics with secrets stripped.

### The practical commuter

Uses a home server but needs dependable playback away from home, on flights, at the gym, or in weak signal areas.

Message:

> Pin the folders and playlists you care about. The app keeps them ready offline and shows exactly what will play when your server is unavailable.

Most important features:

- Manual downloads.
- Smart offline packs.
- Storage budget.
- Offline Mode.
- Resumable downloads where iOS allows.

### The folder-first collector

Has carefully organized folders, box sets, live recordings, DJ sets, lectures, audiobooks, or mixed media that do not fit cleanly into commercial music-app metadata models.

Message:

> Keep your folder structure. Use it as a library, a playlist system, and a playback queue.

Most important features:

- Folder as playlist.
- Recursive actions.
- Natural filename sort.
- Track and disc ordering when metadata exists.
- Play Next, Add to Queue, Save as Playlist.

### The lightweight video user

Mostly wants music, but also has home videos, concerts, tutorials, or downloaded media on the same server.

Message:

> Music comes first, but videos from your server are part of the same personal library.

Most important features:

- Video tab.
- Resume position.
- Basic subtitle and AirPlay expectations later.
- Compatibility backend only when needed.

## Homepage messaging

### Hero

Headline:

> Your NAS music library, built for iPhone.

Subheadline:

> Stream, shuffle, queue, search, and download music from your personal server. Free, open source, no ads, and no required account.

Primary call to action:

> Get the beta

Secondary call to action:

> View source

Trust line:

> Designed for SMB-first local libraries, with WebDAV, FTP/SFTP, and more protocols planned.

### Feature sections

Remote folders that act like a library:

> Add your NAS once, scan your folders, and browse by songs, albums, artists, folders, playlists, and videos. Folders stay first-class, so your organization still matters.

Recursive playback without ceremony:

> Play a folder, shuffle it, or include every subfolder. Build a queue immediately while deeper scanning continues in the background.

Offline packs for real life:

> Pin folders, playlists, favorites, or search results. The app keeps cached media visible and makes offline-only playback obvious.

Private by design:

> No required cloud account. No ads. No tracking-based business model. Credentials belong in Keychain, and the library index belongs on your device.

Open source and donation-supported:

> Core personal streaming stays free. Donations support testing, maintenance, protocol work, and compatibility with real NAS hardware.

Diagnostics that help:

> See whether your server is reachable, how fast it streams, when it was last scanned, and what went wrong when playback fails.

### Homepage proof points to add only after implemented

- "SMB source setup in under 2 minutes."
- "Search tested on 50,000-track libraries."
- "Recursive shuffle starts before a full 10,000-track scan finishes."
- "Cached audio continues from the lock screen."
- "Diagnostics export strips credentials and server secrets."

## App Store messaging

### App name guidance

The name should signal personal media ownership, not a generic file utility. Avoid names that imply cloud hosting, piracy, or video-only playback.

Good naming directions:

- Library/NAS ownership.
- Local-first playback.
- Music-first streaming.
- Simple queue/offline language.

Avoid:

- "Cloud" unless the app truly targets cloud providers.
- "Downloader" as the main concept.
- "VLC-like" or competitor references in public copy.
- Names that sound like a paid streaming service.

### Subtitle options

- NAS music and video player
- Stream your personal library
- Local-server music player
- Private NAS media streaming
- Music-first home server player

### Promotional text

> Stream your personal NAS music library from iPhone. Play folders recursively, build queues, save playlists, and keep favorites offline. Open source, no ads, no required account.

### Short description

> A music-first player for your NAS and local server. Browse folders as a real library, play or shuffle recursively, build persistent queues, cache favorites for offline use, and keep control of your personal media.

### Longer App Store description draft

> Your personal media library should not feel like a file browser.
>
> This app turns music and videos on your NAS or local server into a fast, searchable iPhone library. Add a source, scan your folders, then play, shuffle, queue, playlist, and download the files you already own.
>
> Built for personal servers:
>
> - Add NAS and local-server sources
> - Browse songs, albums, artists, folders, playlists, and videos
> - Play or shuffle folders, including subfolders
> - Build queues from remote files without downloading first
> - Save playlists from files, folders, and search results
> - Cache music for offline listening
> - See what is remote, cached, downloading, or unavailable
> - Keep using your folder structure
>
> Privacy and trust:
>
> - No ads
> - No required account
> - Open-source code
> - Donation-supported development
> - Designed to store credentials securely on device
> - Built for local-first personal libraries
>
> Core personal streaming is free. Optional donations help fund maintenance, testing, and support for more NAS setups and protocols.

### Screenshot story

1. Add your NAS:
   - Show source setup with connection test and root folder selection.
   - Caption: "Add your personal server once."
2. Browse the library:
   - Show Library tabs with albums, songs, folders, and videos.
   - Caption: "Your folders become a real library."
3. Recursive folder actions:
   - Show Play, Shuffle, Play Recursively, Shuffle Recursively.
   - Caption: "Play the folder you meant, including every subfolder."
4. Queue:
   - Show persistent now-playing queue.
   - Caption: "Build queues without downloading first."
5. Offline:
   - Show downloads, pinned folder, storage budget.
   - Caption: "Keep favorites ready offline."
6. Privacy:
   - Show simple settings page, no account requirement, diagnostics controls.
   - Caption: "No ads. No required account. Open source."

### Keyword themes

Use natural App Store keywords around:

- NAS music player
- SMB music player
- local server music
- offline music player
- personal media player
- home server music
- WebDAV music
- FLAC player
- network music player
- folder music player

Do not keyword-stuff competitor names in user-visible copy.

## Launch narrative

The launch story should be specific:

> A lot of people keep music on a NAS, but iPhone apps make them choose between a file browser, a video-first player, or a closed-source app with a broad cloud feature set. This project is a focused open-source alternative: a music-first local-server player where remote folders become a real library.

Launch principles:

- Lead with the user problem, not the protocol list.
- Be direct that SMB is the first deep protocol target.
- Be honest that codec compatibility will improve over time.
- Invite NAS owners to test real-world setups.
- Treat open source as a trust model and collaboration model, not only a license badge.

Beta announcement angle:

> Looking for testers with Synology, QNAP, TrueNAS, Windows shares, and macOS file sharing. The first beta focuses on SMB music libraries, recursive playback, queues, search, and offline caching.

1. Private technical beta:
   - Goal: SMB reliability, scan performance, queue persistence, lock-screen playback.
   - Audience: self-hosters and NAS-heavy music users.
2. Public beta:
   - Goal: onboarding, crash reports, edge cases, file formats, library sizes.
   - Audience: broader personal media users.
3. App Store launch:
   - Goal: stable SMB music experience with transparent roadmap.
   - Audience: users frustrated by file-browser-first remote playback.

## Donation and support framing

Core stance:

> Personal local-server streaming should not be locked behind ads, tracking, or a subscription. Core use stays free. Donations support the work.

What donations fund:

- Real NAS hardware and test environments.
- Protocol compatibility work.
- App Store account and signing costs.
- Accessibility polish.
- Documentation.
- Bug triage and maintenance.
- Compatibility testing for iOS releases.

Good donation language:

- "Support development."
- "Help fund NAS compatibility testing."
- "Keep the core app free."
- "Sponsor open-source maintenance."
- "Contribute if the app is useful to you."

Avoid donation language that implies:

- Users owe payment after using the app.
- Donors receive essential playback features others do not.
- Privacy is funded only if enough users pay.
- The app is free only temporarily.

Acceptable supporter perks:

- Public thanks, if opt-in.
- Supporter badge, if it is cosmetic.
- Early TestFlight access, if it does not lock stable core use.
- Voting or discussion priority for roadmap ideas, without selling guaranteed outcomes.

Do not put these behind donations:

- Core source setup.
- SMB playback.
- Recursive folder playback.
- Basic playlists and queue.
- Offline playback for personal files.
- Privacy controls.
- Security fixes.

## Trust and privacy claims

Only make claims that can be supported by implementation, docs, and source code.

Safe claims once implemented:

- "No ads."
- "No required account."
- "Open source."
- "Core personal streaming is free."
- "Credentials are stored in iOS Keychain."
- "The library index is stored on device."
- "The app does not need a hosted account or server component."
- "Diagnostics are designed to strip credentials before export."
- "Telemetry is off by default" only if telemetry exists and is actually disabled by default.
- "No third-party analytics" only if no analytics SDK is included.

Claims to avoid:

- "Anonymous" unless there is a formal privacy review.
- "Zero data collection" if App Store crash logs, TestFlight feedback, donation platforms, or GitHub interactions collect any data.
- "Never sends data anywhere" if bug reports, update checks, external artwork, donations, or diagnostics can be user-triggered.
- "Secure" without explaining the concrete security property.
- "Private cloud" because this is not a cloud service.
- "Plays everything" before codec compatibility is proven.
- "Background downloads always continue" because iOS limits non-HTTP background work.

Required trust assets before public launch:

- Privacy policy in plain English.
- App Store privacy nutrition labels aligned with actual behavior.
- Security note covering credential storage, diagnostics, logs, and local network permissions.
- Open-source license and dependency license list.
- Clear telemetry policy.
- Clear donation platform disclosure.
- Diagnostics redaction tests.

## Community and open-source strategy

The project should make contribution easy without letting the roadmap become chaotic.

Public repo basics:

- Clear README with product thesis, current status, screenshots, and roadmap.
- CONTRIBUTING.md with build steps, issue policy, coding expectations, and test expectations.
- SECURITY.md with private vulnerability reporting path.
- CODE_OF_CONDUCT.md if community discussion is encouraged.
- LICENSE selected before accepting contributions.
- Dependency license table.

Issue structure:

- Bug report template with iOS version, device, protocol, NAS/server, file type, and reproduction steps.
- NAS compatibility report template.
- Feature request template that asks for workflow and library shape, not just feature name.
- Privacy/security issue template that routes sensitive reports privately.

Community channels:

- GitHub Discussions for setup help, NAS reports, and roadmap discussion.
- GitHub Issues for reproducible bugs and scoped work.
- TestFlight feedback for beta crashes and user-specific setup problems.
- A public compatibility matrix for NAS/server/protocol reports.

Roadmap framing:

- Keep the first public roadmap short and staged.
- Separate "planned", "under investigation", and "not planned now".
- Explain why music-first comes before broad codec parity.
- Explain protocol order: SMB first, WebDAV/HTTP second, FTP/SFTP later, NFS/DLNA after the media model is stable.

Contributor-friendly starter areas:

- Server compatibility reports.
- Documentation.
- Accessibility review.
- Localization.
- File type metadata samples.
- UI polish with screenshots.
- Protocol-specific bug reproduction.

Areas that need maintainer control:

- Credential handling.
- Cache integrity.
- Player abstraction.
- Database schema migrations.
- Dependency additions.
- Privacy-impacting changes.

## Pitfalls to avoid

- Overpromising codec support. Lead with library, queue, offline, and NAS convenience. Add compatibility claims only after testing.
- Sounding anti-VLC or anti-competitor. The better message is that this app solves a different daily-use problem.
- Making "open source" the whole pitch. Users still need a better player.
- Selling privacy as vague virtue. Tie it to concrete behavior: no required account, Keychain credentials, local index, no ads.
- Hiding iOS limitations. Be clear about background download limits, local network permission, and remote-source reliability.
- Making the app look like a downloader. The product is playback and library management; downloads are for offline access.
- Chasing every protocol too early. Depth on SMB music libraries matters more than shallow checkboxes.
- Treating folders as legacy. Folder-first users are the core audience.
- Letting donations feel like guilt or a soft paywall. Keep the tone optional and transparent.
- Publishing App Store privacy claims before the implementation and dependencies are final.
- Using screenshots full of empty states. Show real folders, queue actions, download status, and source health.
- Letting support become private one-off troubleshooting. Convert recurring NAS problems into docs, compatibility notes, and diagnostics.

## Messaging checklist

Before publishing any website, App Store page, README, or launch post, verify:

- The copy says personal NAS/local-server streaming, not generic cloud music.
- The first message is user benefit, not a protocol list.
- The free/open-source/donation model is clear.
- Privacy claims match implemented behavior.
- Core features are not described as donor-only.
- SMB-first scope is visible.
- Offline and background behavior is honest.
- Competitor names are not used as keywords or attack lines.
- Screenshots show actual library workflows.
- The roadmap separates shipped, beta, planned, and later items.
