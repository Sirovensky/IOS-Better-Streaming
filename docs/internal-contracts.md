# Internal Contracts

Date: 2026-06-28

## Purpose

These contracts define the stable internal APIs and behavior that future builders must follow. They are sketches, not final source files, but implementation should stay close unless a builder updates this document with an explicit decision.

The key rule: services share domain identity and state, not raw URLs, UI models, credentials, or renderer-specific objects.

## Global Rules

- Domain types live in `BetterStreamingDomain`.
- Source management lives in `BetterStreamingSources`. Do not create a Swift module named `SourceKit`.
- `RemoteFileSystem` defines protocol-neutral file access.
- `MediaStore` is the only module that imports GRDB.
- Service modules do not import SwiftUI.
- UI uses `@MainActor` view models and state structs.
- Long-running work is `async`, cancellable, and reports progress through `AsyncSequence` or a `ProgressSink`.
- Public shared types crossing concurrency boundaries are `Sendable`.
- Credentials never leave `BetterStreamingSources` except as authenticated connection/session objects that cannot be logged or serialized.
- Playback renderers receive local files or loopback URLs only, never `smb://` URLs with credentials.
- Logs and diagnostics call the shared redaction helper before emitting URLs, paths, hostnames, usernames, tokens, or errors that may contain secrets.

## Identity Rules

Never use a plain URL string as media identity. Persisted remote media identity is:

```text
source_id + share_id + normalized_remote_path + remote_file_id_if_available + size + modified_at
```

Rules:

- `SourceID` is stable across credential changes.
- `ShareID` is stable across host alias repair when the user confirms the repair.
- `RemotePath` preserves display names but compares through protocol-specific normalization.
- `remoteFileID` is optional. Many protocols will not provide one.
- Path changes are repairable. Match candidates by size, modified time, duration, and later audio fingerprint.
- UI code must not compare raw protocol URLs.

Core type sketches:

```swift
public struct SourceID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct ShareID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct MediaItemID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct FolderID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct PlaylistID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct QueueID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct RemoteFileID: Hashable, Codable, Sendable {
    public let rawValue: String
}

public struct RemotePath: Hashable, Codable, Sendable {
    public let displayPath: String
    public let normalizedPath: String

    public func appending(_ component: String, normalizer: RemotePathNormalizer) -> RemotePath
}

public struct RemoteItemIdentity: Hashable, Codable, Sendable {
    public let sourceID: SourceID
    public let shareID: ShareID
    public let path: RemotePath
    public let remoteFileID: RemoteFileID?
    public let size: Int64?
    public let modifiedAt: Date?
}
```

`normalizedPath` is for equality and lookup. `displayPath` is for UI. Builders must not render `normalizedPath` unless a debug view explicitly asks for it.

## Error Contracts

Errors must be typed enough for UI and diagnostics. They must also be redaction-safe.

```swift
public protocol RedactableError: Error, Sendable {
    var userMessage: String { get }
    var diagnosticsCode: String { get }
    var redactedDebugDescription: String { get }
}

public enum SourceError: RedactableError {
    case localNetworkDenied
    case authenticationFailed
    case hostUnreachable
    case shareNotFound
    case unsupportedConfiguration
    case keychainFailure(code: OSStatus)
    case cancelled
}

public enum RemoteFileSystemError: RedactableError {
    case notFound(RemotePath)
    case permissionDenied(RemotePath)
    case authenticationExpired
    case timeout
    case serverDisconnected
    case unsupportedRange
    case staleFileHandle
    case invalidResponse
    case cancelled
}

public enum PlaybackError: RedactableError {
    case sourceUnavailable(MediaItemID)
    case cacheRequired(MediaItemID)
    case unsupportedFormat(MediaItemID, reason: String)
    case rendererFailed(MediaItemID, renderer: PlaybackRendererKind, code: String)
    case interrupted
    case cancelled
}
```

`userMessage` is short and human. `diagnosticsCode` is stable for filtering. `redactedDebugDescription` may include technical context but no secrets.

## Source Contract

`BetterStreamingSources` owns saved source records, credential references, Keychain access, discovery, source health, and repair.

It must not expose passwords or credential-bearing URLs.

```swift
public enum SourceProtocolKind: String, Codable, Sendable {
    case smb
    case webDAV
    case ftp
    case sftp
    case nfs
    case dlna
}

public struct SourceRecord: Identifiable, Codable, Sendable {
    public let id: SourceID
    public var displayName: String
    public var protocolKind: SourceProtocolKind
    public var endpoint: SourceEndpoint
    public var credentialRef: CredentialRef?
    public var roots: [SourceRoot]
    public var createdAt: Date
    public var updatedAt: Date
}

public struct SourceEndpoint: Codable, Sendable {
    public var hostDisplayName: String
    public var hostFingerprint: String?
    public var port: Int?
    public var shareName: String?
}

public struct CredentialRef: Hashable, Codable, Sendable {
    public let keychainService: String
    public let account: String
}

public struct SourceRoot: Identifiable, Codable, Sendable {
    public let id: ShareID
    public var path: RemotePath
    public var mediaKind: RootMediaKind
    public var displayName: String
}

public enum RootMediaKind: String, Codable, Sendable {
    case music
    case video
    case mixed
}

public struct SourceDraft: Sendable {
    public var protocolKind: SourceProtocolKind
    public var displayName: String
    public var endpoint: SourceEndpoint
    public var username: String?
    public var domain: String?
}

public struct CredentialSecret: Sendable {
    public let password: String
}

public struct SourceHealthSnapshot: Codable, Sendable {
    public var sourceID: SourceID
    public var state: SourceHealthState
    public var lastCheckedAt: Date
    public var speedSample: SpeedSample?
    public var capabilities: RemoteCapabilities?
    public var userMessage: String?
}

public enum SourceHealthState: String, Codable, Sendable {
    case unknown
    case online
    case asleep
    case authFailed
    case localNetworkBlocked
    case unreachable
    case degraded
}

public protocol SourceRegistry: Sendable {
    func listSources() async throws -> [SourceRecord]
    func source(id: SourceID) async throws -> SourceRecord?
    func saveSource(_ draft: SourceDraft, credential: CredentialSecret?) async throws -> SourceRecord
    func updateCredential(for sourceID: SourceID, credential: CredentialSecret) async throws
    func deleteSource(_ sourceID: SourceID) async throws
    func testSource(_ sourceID: SourceID) async throws -> SourceHealthSnapshot
    func listRoots(for sourceID: SourceID) async throws -> [RemoteEntry]
    func openFileSystem(sourceID: SourceID, shareID: ShareID) async throws -> any RemoteFileSystemClient
    func repairSource(_ sourceID: SourceID, proposal: SourceRepairProposal) async throws -> SourceRecord
}
```

Expected behavior:

- `saveSource` validates enough to store a coherent source but does not require a full library scan.
- `testSource` performs auth, reachability, capability, and speed checks when cheap.
- `openFileSystem` returns an authenticated client or throws a typed `SourceError`.
- `deleteSource` removes credentials from Keychain and marks related store records through `MediaStore` coordination.
- `repairSource` changes endpoint/root mapping only after user confirmation.

Example:

```swift
let source = try await sourceRegistry.saveSource(draft, credential: secret)
let health = try await sourceRegistry.testSource(source.id)
guard health.state == .online else { return }
let roots = try await sourceRegistry.listRoots(for: source.id)
```

## RemoteFileSystem Contract

`RemoteFileSystem` is protocol-neutral file access. It does not know about Keychain, GRDB, AVPlayer, playlists, or SwiftUI.

```swift
public struct RemoteCapabilities: Codable, Sendable {
    public var supportsByteRangeRead: Bool
    public var supportsServerSideSearch: Bool
    public var supportsStableFileID: Bool
    public var supportsDirectoryModifiedTime: Bool
    public var supportsBackgroundURLSession: Bool
}

public enum RemoteEntryKind: String, Codable, Sendable {
    case file
    case directory
    case symbolicLink
    case unknown
}

public struct RemoteEntry: Identifiable, Codable, Sendable {
    public let id: RemoteItemIdentity
    public var name: String
    public var path: RemotePath
    public var kind: RemoteEntryKind
    public var size: Int64?
    public var modifiedAt: Date?
    public var contentType: String?
}

public struct RemoteMetadata: Codable, Sendable {
    public let identity: RemoteItemIdentity
    public var kind: RemoteEntryKind
    public var size: Int64?
    public var modifiedAt: Date?
    public var contentType: String?
    public var supportsRangeRead: Bool
}

public protocol ProgressSink: Sendable {
    func update(bytesDone: Int64, bytesTotal: Int64?) async
}

public protocol RemoteFileSystemClient: Sendable {
    var sourceID: SourceID { get }
    var shareID: ShareID { get }
    var capabilities: RemoteCapabilities { get async }

    func list(_ directory: RemotePath) async throws -> [RemoteEntry]
    func stat(_ path: RemotePath) async throws -> RemoteMetadata
    func read(_ path: RemotePath, range: Range<Int64>) async throws -> Data
    func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink?) async throws
}
```

Expected behavior:

- `list` returns direct children only. Recursion belongs in `LibraryIndexer`.
- `list` does not need to sort. Store/indexer applies natural sort.
- `stat` must be cheap enough to call before playback.
- `read` uses half-open byte ranges. It returns exactly the requested bytes unless EOF is reached.
- `read` must be cancellable and must not swallow cancellation as a generic failure.
- `download` writes to a temporary file first and atomically moves into `localURL` when complete.
- Adapters map native errors into `RemoteFileSystemError`.
- Range-unsupported sources throw `.unsupportedRange`; callers may cache-before-play.

Example:

```swift
let metadata = try await remote.stat(trackPath)
let firstChunk = try await remote.read(trackPath, range: 0..<min(metadata.size ?? 64_000, 64_000))
try await remote.download(trackPath, to: cacheURL, progress: progressSink)
```

## MediaStore Contract

`MediaStore` owns persistence. It is the only module that imports GRDB and the only module that manages schema migrations.

```swift
public struct MediaItem: Identifiable, Codable, Sendable {
    public let id: MediaItemID
    public var identity: RemoteItemIdentity
    public var parentFolderID: FolderID?
    public var mediaKind: MediaKind
    public var fileName: String
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?
    public var sortKey: String
    public var playbackCapability: PlaybackCapability?
}

public enum MediaKind: String, Codable, Sendable {
    case audio
    case video
    case other
}

public struct FolderItem: Identifiable, Codable, Sendable {
    public let id: FolderID
    public var identity: RemoteItemIdentity
    public var parentFolderID: FolderID?
    public var name: String
    public var scanState: ScanState
    public var sortKey: String
}

public enum ScanState: String, Codable, Sendable {
    case unscanned
    case scanning
    case partial
    case complete
    case failed
}

public protocol MediaStore: Sendable {
    func migrate() async throws

    func upsertSource(_ source: SourceRecord) async throws
    func upsertFolder(_ folder: FolderItem) async throws
    func upsertMediaItems(_ items: [MediaItem]) async throws
    func markFolderScanState(_ folderID: FolderID, state: ScanState) async throws

    func folder(id: FolderID) async throws -> FolderItem?
    func mediaItem(id: MediaItemID) async throws -> MediaItem?
    func children(of folderID: FolderID) async throws -> FolderChildren
    func search(_ query: LibrarySearchQuery) async throws -> LibrarySearchResult

    func saveScanCheckpoint(_ checkpoint: ScanCheckpoint) async throws
    func scanCheckpoint(for request: ScanRequest) async throws -> ScanCheckpoint?

    func saveQueueSnapshot(_ snapshot: PlaybackQueueSnapshot) async throws
    func loadQueueSnapshot() async throws -> PlaybackQueueSnapshot?

    func upsertCacheRecord(_ record: CacheRecord) async throws
    func cacheRecord(for mediaItemID: MediaItemID) async throws -> CacheRecord?
}
```

Expected behavior:

- Writes that describe one scan batch happen in one transaction.
- Upserts preserve stable IDs when identity matches.
- FTS updates happen in the same transaction as item changes.
- Store APIs are async even when backed by synchronous GRDB calls, so callers do not block the main actor.
- Store methods return domain models, not GRDB rows.
- UI may observe via feature repositories or async streams, but never runs SQL.

## LibraryIndexer Contract

`LibraryIndexer` performs progressive scans. It consumes `RemoteFileSystemClient` and `MediaStore`. It does not render UI and does not start playback.

```swift
public struct ScanID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct ScanRequest: Hashable, Codable, Sendable {
    public var sourceID: SourceID
    public var shareID: ShareID
    public var rootPath: RemotePath
    public var mode: ScanMode
}

public enum ScanMode: String, Codable, Sendable {
    case pathOnly
    case pathAndCheapMetadata
    case rescan
    case repairCandidateSearch
}

public struct ScanProgress: Codable, Sendable {
    public var scanID: ScanID
    public var foldersVisited: Int
    public var filesVisited: Int
    public var mediaItemsFound: Int
    public var currentPath: RemotePath?
    public var isCheckpointed: Bool
}

public enum ScanEvent: Sendable {
    case started(ScanID)
    case progress(ScanProgress)
    case folderUpdated(FolderID)
    case mediaBatchInserted([MediaItemID])
    case completed(ScanID)
    case failed(ScanID, any RedactableError)
    case cancelled(ScanID)
}

public protocol LibraryIndexer: Sendable {
    func startScan(_ request: ScanRequest) async throws -> ScanID
    func events(for scanID: ScanID) -> AsyncStream<ScanEvent>
    func pause(_ scanID: ScanID) async
    func resume(_ scanID: ScanID) async throws
    func cancel(_ scanID: ScanID) async
}
```

Expected behavior:

- Path-first records are inserted before expensive metadata extraction.
- Scans checkpoint often enough to survive process death without restarting huge libraries from zero.
- Cancellation is cooperative and persists the latest checkpoint.
- Subtree scans do not invalidate unrelated roots.
- Recursive playback can consume partial scan results while traversal continues.
- Metadata extraction is scheduled separately and must not block folder playback.

Example:

```swift
let scanID = try await indexer.startScan(.init(
    sourceID: source.id,
    shareID: root.id,
    rootPath: root.path,
    mode: .pathOnly
))

for await event in indexer.events(for: scanID) {
    // View model maps events into ScanUIState on the main actor.
}
```

## CacheManager Contract

`CacheManager` owns playback byte cache and durable offline cache. It does not choose queue order and does not know source credentials.

```swift
public enum CacheState: String, Codable, Sendable {
    case remoteOnly
    case queued
    case downloading
    case cached
    case prefetched
    case stale
    case failed
    case evicted
}

public enum CacheRequiredBy: Hashable, Codable, Sendable {
    case manual
    case folder(FolderID, recursive: Bool)
    case playlist(PlaylistID)
    case smartPack(String)
    case queuePrefetch(QueueID)
}

public struct CacheRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public var mediaItemID: MediaItemID
    public var identity: RemoteItemIdentity
    public var state: CacheState
    public var localFileURL: URL?
    public var bytesTotal: Int64?
    public var bytesDone: Int64
    public var requiredBy: Set<CacheRequiredBy>
    public var lastPlayedAt: Date?
    public var lastVerifiedAt: Date?
    public var failureCode: String?
}

public struct CacheJobID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct CacheRequest: Sendable {
    public var items: [MediaItemID]
    public var requiredBy: CacheRequiredBy
    public var priority: CachePriority
}

public enum CachePriority: String, Codable, Sendable {
    case userInitiated
    case playback
    case prefetch
    case maintenance
}

public enum PlayableAsset: Sendable {
    case localFile(URL)
    case requiresStream(MediaItemID)
    case unavailable(CacheUnavailableReason)
}

public enum CacheUnavailableReason: String, Codable, Sendable {
    case sourceOffline
    case notCached
    case downloadFailed
    case fileMissing
    case staleAndRemoteUnavailable
}

public protocol CacheManager: Sendable {
    func record(for mediaItemID: MediaItemID) async throws -> CacheRecord?
    func playableAsset(for mediaItemID: MediaItemID, offlineMode: Bool) async throws -> PlayableAsset

    func pin(_ request: CacheRequest) async throws -> CacheJobID
    func unpin(mediaItemID: MediaItemID, requiredBy: CacheRequiredBy) async throws
    func ensureCompleteFile(for mediaItemID: MediaItemID, priority: CachePriority) async throws -> URL

    func readCachedBytes(for mediaItemID: MediaItemID, range: Range<Int64>) async throws -> Data?
    func storeCachedBytes(for mediaItemID: MediaItemID, range: Range<Int64>, data: Data) async throws

    func events(for jobID: CacheJobID) -> AsyncStream<CacheEvent>
    func enforceQuota() async throws
}
```

Expected behavior:

- Complete-file cache and byte cache are separate layers.
- Complete downloads use temp files and atomic moves.
- Active playback cache files use a file-protection class compatible with lock-screen playback after first unlock.
- `playableAsset(offlineMode: true)` never returns a stream requirement for uncached media.
- Pinned files survive quota eviction unless the user removes the pin or lowers quota below pinned size with confirmation.
- Partial files are recoverable or cleaned up deterministically.
- Cache state is persisted through `MediaStore`.

Example:

```swift
let localURL = try await cache.ensureCompleteFile(for: mediaItemID, priority: .playback)
try await playback.load(.items([mediaItemID]), startAt: mediaItemID)
```

## StreamBridge Contract

`StreamBridge` turns remote byte reads into renderer-safe playback sources. Renderers receive only local files or loopback URLs.

```swift
public enum PlaybackSource: Sendable {
    case localFile(URL)
    case loopbackHTTP(URL, token: String)
}

public struct StreamSessionID: Hashable, Codable, Sendable {
    public let rawValue: UUID
}

public struct StreamRequest: Sendable {
    public var mediaItemID: MediaItemID
    public var identity: RemoteItemIdentity
    public var contentType: String?
    public var expectedLength: Int64?
}

public protocol PlaybackSourceFactory: Sendable {
    func source(for mediaItemID: MediaItemID, preference: PlaybackSourcePreference) async throws -> PlaybackSource
}

public enum PlaybackSourcePreference: String, Codable, Sendable {
    case preferLocalFile
    case allowStream
    case requireLocalFile
}

public protocol StreamBridge: Sendable {
    func startSession(_ request: StreamRequest, remote: any RemoteFileSystemClient) async throws -> (StreamSessionID, PlaybackSource)
    func stopSession(_ id: StreamSessionID) async
    func activeSessions() async -> [StreamSessionID]
}
```

Loopback requirements:

- Bind only to `127.0.0.1` and `::1`.
- Use a random port and per-item tokenized URLs.
- Support `HEAD`.
- Support `GET` with `Range`.
- Return correct `200`, `206`, and `416` responses.
- Return stable `Content-Length`, `Content-Range`, `Accept-Ranges`, `Content-Type`, `ETag`, and `Last-Modified` when known.
- Handle overlapping range requests.
- Apply backpressure and cancellation.
- Serve already-cached chunks before remote reads.
- Never expose credentials, usernames, hostnames, or raw remote paths in URLs or logs.

Expected behavior:

- `StreamBridge` does not decide queue order.
- `StreamBridge` does not own durable offline policy.
- Every stream failure falls back to cache-before-play when possible.
- `AVAssetResourceLoader` implementations must live behind the same `PlaybackSourceFactory`.

## PlaybackCore Contract

`PlaybackCore` owns queue state, playback state, renderer selection, system media integration, and persistence coordination. It does not know whether an item came from SMB, WebDAV, cache, or a stream bridge.

```swift
public enum PlaybackRendererKind: String, Codable, Sendable {
    case avFoundation
    case vlcCompatibility
}

public enum RepeatMode: String, Codable, Sendable {
    case off
    case all
    case one
}

public struct QueueItem: Identifiable, Codable, Sendable {
    public let id: UUID
    public var mediaItemID: MediaItemID
    public var source: QueueInsertionSource
}

public enum QueueInsertionSource: Codable, Sendable {
    case folder(FolderID, recursive: Bool)
    case playlist(PlaylistID)
    case search(String)
    case manual
}

public struct PlaybackQueueSnapshot: Codable, Sendable {
    public var queueID: QueueID
    public var items: [QueueItem]
    public var currentIndex: Int?
    public var shuffleEnabled: Bool
    public var repeatMode: RepeatMode
    public var savedAt: Date
}

public struct PlaybackCandidate: Sendable {
    public var itemID: MediaItemID
    public var renderer: PlaybackRendererKind
    public var source: PlaybackSource
    public var supportsBackgroundAudio: Bool
    public var supportsAirPlay: Bool
    public var supportsPiP: Bool
    public var limitations: [PlaybackLimitation]
}

public protocol PlaybackRenderer: Sendable {
    var kind: PlaybackRendererKind { get }
    func probe(_ source: PlaybackSource) async -> ProbeResult
    func prepare(_ candidate: PlaybackCandidate) async throws
    func play() async
    func pause() async
    func seek(to time: CMTime) async throws
    func stop() async
}

public enum PlaybackEvent: Sendable {
    case queueChanged(PlaybackQueueSnapshot)
    case nowPlayingChanged(MediaItemID?)
    case stateChanged(PlaybackTransportState)
    case elapsedTimeChanged(TimeInterval)
    case failed(MediaItemID, PlaybackError)
}

public enum PlaybackTransportState: String, Codable, Sendable {
    case idle
    case preparing
    case playing
    case paused
    case buffering
    case failed
}

public protocol PlaybackCore: Sendable {
    func load(_ seed: PlaybackQueueSeed, startAt: MediaItemID?) async throws
    func play() async throws
    func pause() async
    func togglePlayPause() async throws
    func seek(to time: TimeInterval) async throws
    func skipToNext() async throws
    func skipToPrevious() async throws

    func playNext(_ items: [MediaItemID]) async throws
    func append(_ items: [MediaItemID]) async throws
    func reorder(fromOffsets: IndexSet, toOffset: Int) async throws
    func clearQueue() async throws
    func setShuffleEnabled(_ enabled: Bool) async throws
    func setRepeatMode(_ mode: RepeatMode) async throws

    func snapshot() async -> PlaybackQueueSnapshot
    func events() -> AsyncStream<PlaybackEvent>
}
```

Expected behavior:

- Queue semantics are deterministic and unit tested.
- Shuffle uses a stored order so relaunch does not reshuffle unexpectedly.
- Renderer selection is deterministic:
  1. Use cached local file with AVPlayer when probe succeeds.
  2. Use loopback stream with AVPlayer when probe succeeds.
  3. Use VLCKit only when available, gated, and needed.
  4. If no renderer works, mark the item unsupported and keep it visible.
- Renderers do not own the app queue.
- Renderer switches happen only between items or after hard failure and explicit restart of that item.
- Playback persists queue snapshots through `MediaStore`.
- Now Playing, remote commands, interruptions, and route changes are part of `PlaybackCore`.

Example:

```swift
try await playback.load(.folder(folderID, recursive: false, shuffle: false), startAt: nil)
try await playback.play()
try await playback.setRepeatMode(.all)
```

## PlaylistCore Contract

`PlaylistCore` owns durable playlists. A queue is transient playback state; a playlist is library state.

```swift
public struct Playlist: Identifiable, Codable, Sendable {
    public let id: PlaylistID
    public var name: String
    public var entries: [PlaylistEntry]
    public var createdAt: Date
    public var updatedAt: Date
}

public enum PlaylistEntry: Identifiable, Codable, Sendable {
    case media(MediaItemID)
    case folder(FolderID, recursive: Bool)
    case liveFolder(FolderID, recursive: Bool)

    public var id: String { get }
}

public struct PlaylistImportResult: Sendable {
    public var playlistID: PlaylistID
    public var resolvedCount: Int
    public var unresolvedEntries: [UnresolvedPlaylistEntry]
}

public protocol PlaylistCore: Sendable {
    func createPlaylist(name: String) async throws -> Playlist
    func playlist(id: PlaylistID) async throws -> Playlist?
    func listPlaylists() async throws -> [Playlist]
    func renamePlaylist(_ id: PlaylistID, name: String) async throws
    func deletePlaylist(_ id: PlaylistID) async throws

    func addEntries(_ entries: [PlaylistEntry], to playlistID: PlaylistID) async throws
    func removeEntries(at offsets: IndexSet, from playlistID: PlaylistID) async throws
    func reorderEntries(in playlistID: PlaylistID, fromOffsets: IndexSet, toOffset: Int) async throws
    func resolveEntries(for playlistID: PlaylistID) async throws -> [MediaItemID]

    func importM3U(from url: URL, sourceHint: SourceID?) async throws -> PlaylistImportResult
    func exportM3U(playlistID: PlaylistID, to url: URL) async throws
    func setOfflinePinned(_ pinned: Bool, playlistID: PlaylistID) async throws
}
```

Expected behavior:

- Playlists may contain remote-only items.
- Live folder entries resolve through current library state at playback/cache time.
- Playlist pinning creates cache intent; it does not download inline on the main actor.
- Imported paths either resolve to stable identities or produce repair warnings.
- Playlist editing does not mutate the current playback queue unless the user explicitly loads it.

## Diagnostics Contract

`Diagnostics` explains source, scan, cache, and playback failures. It treats secrets as toxic by default.

```swift
public struct SpeedSample: Codable, Sendable {
    public var bytesPerSecond: Double
    public var measuredAt: Date
    public var sampleSizeBytes: Int64
    public var recommendation: StreamRecommendation
}

public enum StreamRecommendation: String, Codable, Sendable {
    case streamOK
    case preCacheRecommended
    case offlineOnlyRecommended
    case unknown
}

public struct DiagnosticBundle: Sendable {
    public var localURL: URL
    public var createdAt: Date
}

public protocol Diagnostics: Sendable {
    func speedTest(sourceID: SourceID, shareID: ShareID, path: RemotePath?) async throws -> SpeedSample
    func classify(_ error: Error) -> DiagnosticClassification
    func sourceSnapshot(_ sourceID: SourceID) async throws -> SourceHealthSnapshot
    func exportDebugBundle(scope: DiagnosticScope) async throws -> DiagnosticBundle
    func redact(_ value: String) -> String
}
```

Expected behavior:

- User-facing diagnostics start with plain language.
- Technical details include stable codes and redacted context.
- Debug bundles strip credentials, tokens, raw usernames, credential-bearing URLs, and sensitive connection strings.
- Full paths and filenames are included only when the user explicitly exports a bundle and redaction rules allow them.
- Redaction has tests with realistic SMB/WebDAV URLs and error messages.

## UI State Contracts

UI state lives in the app target or feature UI modules. Service modules return domain state; view models map it into presentation state on the main actor.

```swift
@MainActor
public protocol FeatureViewModel: ObservableObject {
    associatedtype State: Sendable
    var state: State { get }
}

public enum Loadable<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(message: String, code: String)
}

public enum MediaAvailability: String, Codable, Sendable {
    case cached
    case downloading
    case queued
    case prefetched
    case stale
    case remoteOnly
    case missingSource
    case failed
}

public struct MediaRowState: Identifiable, Sendable {
    public var id: MediaItemID
    public var title: String
    public var subtitle: String
    public var detail: String?
    public var artworkID: String?
    public var availability: MediaAvailability
    public var isPlayable: Bool
    public var actions: [MediaAction]
}

public struct FolderRowState: Identifiable, Sendable {
    public var id: FolderID
    public var name: String
    public var pathSummary: String
    public var scanState: ScanState
    public var availability: MediaAvailability
    public var canPlayCurrentFolder: Bool
    public var canPlayRecursively: Bool
    public var progressiveCount: Int?
}

public enum MediaAction: String, Codable, Sendable {
    case play
    case shuffle
    case playNext
    case addToQueue
    case addToPlaylist
    case download
    case revealInFolder
    case info
}

public struct PlaybackUIState: Sendable {
    public var transportState: PlaybackTransportState
    public var nowPlayingID: MediaItemID?
    public var title: String
    public var subtitle: String
    public var elapsed: TimeInterval
    public var duration: TimeInterval?
    public var availability: MediaAvailability
    public var queueCount: Int
}

public struct SourceUIState: Identifiable, Sendable {
    public var id: SourceID
    public var name: String
    public var protocolLabel: String
    public var health: SourceHealthState
    public var lastScanLabel: String?
    public var speedLabel: String?
    public var recommendation: StreamRecommendation
}
```

UI behavior rules:

- `isPlayable` must come from playback/cache/source readiness, not from file extension alone.
- Offline rows can stay visible, but remote-only rows are dimmed and disabled when offline.
- Status is never color-only. Pair every state with icon and label.
- Long paths are middle-truncated in row summaries and available in detail views.
- The Library first screen contains working library controls, not marketing copy once a source exists.
- Setup starts from "Add Source" in a Library shell, not a standalone protocol picker.
- Advanced protocol fields live behind an expansion control.

Example view-model flow:

```swift
@MainActor
final class FolderViewModel: ObservableObject {
    @Published private(set) var state: Loadable<[FolderRowState]> = .idle

    func play(folderID: FolderID) async {
        do {
            try await playback.load(.folder(folderID, recursive: false, shuffle: false), startAt: nil)
            try await playback.play()
        } catch {
            state = .failed(message: diagnostics.classify(error).userMessage,
                            code: diagnostics.classify(error).code)
        }
    }
}
```

## Cross-Module Usage Examples

### Add Source, Scan, Browse

```swift
let source = try await sourceRegistry.saveSource(draft, credential: secret)
let health = try await sourceRegistry.testSource(source.id)
guard health.state == .online else { return }

let remote = try await sourceRegistry.openFileSystem(sourceID: source.id, shareID: root.id)
let scanID = try await indexer.startScan(.init(
    sourceID: source.id,
    shareID: root.id,
    rootPath: root.path,
    mode: .pathOnly
))
```

### Play Current Folder Cache-First

```swift
let children = try await mediaStore.children(of: folderID)
let playableIDs = children.mediaItems.filter { $0.mediaKind == .audio }.map(\.id)

try await playback.load(.items(playableIDs), startAt: playableIDs.first)
try await playback.play()
```

`PlaybackCore` asks its resolver for a `PlaybackSource`. The resolver prefers cached local files, asks `CacheManager` to cache when required, or asks `StreamBridge` for a loopback URL when streaming is allowed.

### Pin Playlist Offline

```swift
try await playlistCore.setOfflinePinned(true, playlistID: playlistID)
let itemIDs = try await playlistCore.resolveEntries(for: playlistID)
_ = try await cache.pin(.init(
    items: itemIDs,
    requiredBy: .playlist(playlistID),
    priority: .userInitiated
))
```

## Contract Change Rule

Builders may refine names during implementation, but must not change behavior silently. If a module needs a different boundary, update this document and the relevant tests in the same change.
