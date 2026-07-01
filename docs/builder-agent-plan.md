# Builder Agent Plan

Date: 2026-06-28

## Recommendation

Build the app as a runnable iOS 17 SwiftUI shell plus local Swift package first, then split agents by module ownership. Do not start with broad UI polish, WebDAV, video, VLCKit, playlists, or range streaming. The fastest credible route is:

```text
project/app shell
-> core package targets and contracts
-> fake library path
-> SMB source path
-> path scan
-> cache-first AVQueuePlayer playback
-> real-device lock-screen check
```

Use the iPhone 17 Pro as soon as the shell can launch. Simulator is fine for compile/UI smoke, but Local Network permission, Keychain, background audio, Now Playing, remote commands, interruption, route changes, and app suspension must be verified on device.

## Main Agent Scaffolds First

Do this serially before spawning builders:

1. Add `project.yml`, app target, package target list, schemes, entitlements, Info.plist purpose strings, and empty source folders exactly matching `docs/build-structure.md`.
2. Add `Packages/BetterStreamingCore/Package.swift` with empty compilable targets:
   `BetterStreamingDomain`, `AppFoundation`, `RemoteFileSystem`, `SMBRemote`, `BetterStreamingSources`, `MediaStore`, `LibraryIndexer`, `CacheManager`, `StreamBridge`, `PlaybackCore`, `PlaylistCore`, `MetadataCore`, `Diagnostics`, `TestSupport`.
3. Add the SwiftUI app shell: Library first screen, tab structure placeholders, source setup entry, mini-player placeholder, semantic color/token file.
4. Add local commands/scripts:
   `xcodegen generate`, simulator build, package tests, format.
5. Add only placeholder module APIs needed for parallel work. Keep `project.yml` ownership with the main agent until the first milestone builds.

Do not let multiple agents edit `project.yml`, generated `.xcodeproj`, package manifest target lists, entitlements, or Info.plist at the same time.

## Spawn Next

Spawn these after the shell compiles. Keep write scopes strict.

| Agent | Write scope | First output | Dependencies |
| --- | --- | --- | --- |
| Domain/Store | `Packages/BetterStreamingCore/Sources/BetterStreamingDomain/**`, `Sources/MediaStore/**`, `Tests/BetterStreamingDomainTests/**`, `Tests/MediaStoreTests/**` | Identity types, scan/cache/queue models, GRDB migrations for sources/folders/media/queue/cache/checkpoints | Main scaffold only |
| RFS/Fake/Indexer | `Sources/RemoteFileSystem/**`, `Sources/LibraryIndexer/**`, `Sources/TestSupport/**`, `Tests/RemoteFileSystemTests/**`, `Tests/LibraryIndexerTests/**`, `Tools/fixtures/**` | Fake filesystem, path-first scan, cancellation/checkpoint tests, fixture tree | Domain types |
| SMB/Sources | `Sources/SMBRemote/**`, `Sources/BetterStreamingSources/**`, `Tests/SMBRemoteIntegrationTests/**`, source tests | Keychain wrapper, SMB adapter, manual source save/test/list roots, redacted errors | RemoteFileSystem contract |
| Playback/Cache | `Sources/CacheManager/**`, `Sources/PlaybackCore/**`, `Tests/CacheManagerTests/**`, `Tests/PlaybackCoreTests/**` | Complete-file cache, AVQueuePlayer renderer, queue snapshot persistence hooks, Now Playing hooks | Domain and MediaStore APIs |
| App UI | `App/BetterStreaming/Features/**`, `App/BetterStreaming/Navigation/**`, `App/BetterStreaming/Resources/**` | Library/Folders/Source Setup/Player screens wired first to fake services, then real services | App shell, UI state contracts |
| Diagnostics | `Sources/AppFoundation/**`, `Sources/Diagnostics/**`, `Tests/DiagnosticsTests/**` | Shared redaction helper, typed classifications, redaction tests | Error enums from Domain/RFS/Sources |

## Serial vs Parallel

Serial:

- Project scaffolding and manifest wiring.
- Domain identity names and error enums.
- First GRDB migration sequence.
- App environment dependency injection shape.
- Source setup fields and Local Network/Keychain copy.
- AVAudioSession/Now Playing/remote command integration on device.

Parallel:

- Store migrations and repositories while fake filesystem/indexer builds against domain models.
- SMB adapter while UI uses fake source data.
- Folders UI while scanner/store APIs stabilize.
- Cache and pure queue logic while SMB/source setup is being integrated.
- Diagnostics redaction tests alongside all source/playback work.

Hard stop rules:

- One migration owner at a time.
- One owner for `project.yml` until the first milestone is green.
- Service modules never import SwiftUI.
- `MediaStore` is the only module importing GRDB.
- Playback renderers receive local files or loopback URLs only, never credentialed remote URLs.
- Credentials stay inside `BetterStreamingSources` and Keychain.

## Conflict Avoidance

- Main agent creates all target folders up front so agents only add files inside owned scopes.
- Agents may add tests only under their matching test folders.
- Agents must not edit generated `BetterStreaming.xcodeproj`.
- Agents must not rename shared domain types without coordinating with the main agent.
- Agents must not add dependencies directly; propose them to the main agent for `Package.swift`/decision docs.
- UI agent uses feature view models and fake repositories until real services land.
- SMB integration tests must be opt-in and use untracked local config or environment variables.
- Every log/diagnostic path must go through the shared redaction helper.

## First Verifiable App Milestone

Target this before broader feature work:

```text
Fresh install on simulator and iPhone 17 Pro
-> app opens to Library
-> Add SMB Source flow saves credentials to Keychain
-> test/list root succeeds on a local share
-> choose a Music root
-> path-first scan inserts folders/files progressively
-> Folders screen shows partial scan state
-> Play Folder downloads first playable audio file to cache
-> AVQueuePlayer starts playback
-> lock device and verify audio continues with play/pause from Lock Screen
-> relaunch and restore queue context
```

Milestone checks:

- `xcodegen generate` succeeds.
- Simulator build succeeds for a current iPhone destination.
- `swift test --package-path Packages/BetterStreamingCore` succeeds.
- On iPhone 17 Pro, Local Network permission copy appears, Keychain round-trip works, cached audio continues after lock, and remote play/pause works.
- No logs, SQLite rows, filenames, diagnostics, or URLs contain passwords or credential-bearing SMB URLs.

Until this milestone is green, defer WebDAV, video, VLCKit, album/artist screens, playlists, M3U, durable offline packs, custom player polish, and range streaming beyond the cache-first fallback.
