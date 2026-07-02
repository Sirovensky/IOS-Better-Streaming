import AVFoundation
import EvensongDomain
import Foundation
import ImageIO
import FTPRemote
import LibraryIndexer
import MediaStore
import MetadataReader
import RemoteFileSystem
import SFTPRemote
import SMBRemote
#if canImport(WebDAVRemote)
import WebDAVRemote
#endif

/// App-level scan error so AppModel can surface a real reason (and not import
/// Core's Domain types, which would clash with the app's own enums).
struct LibraryError: Error, Sendable {
    enum Kind: Sendable { case auth, notFound, unreachable, other }
    let kind: Kind
    let message: String
}

/// A directory entry for the interactive folder picker (App-facing, no Core types).
struct RemoteFolder: Identifiable, Sendable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

/// Persistable connection config for a source (no password — that's in Keychain).
struct SourceConfig: Codable, Sendable, Identifiable {
    var id: String          // SourceID uuid string
    var shareID: String     // ShareID uuid string
    var name: String
    var proto: String       // SourceProtocol.rawValue: "SMB" / "WebDAV" / ...
    var host: String
    var port: Int
    var share: String       // SMB share name, or base path for others
    var username: String?
    var domain: String?
    var rootPath: String    // path within the share to scan
    var bookmark: String? = nil   // base64 security-scoped bookmark for local sources
}

/// One inferred metadata override in a bulk auto-fix. Only the non-nil fields are
/// applied, so a broken artist can be filled without touching a good title.
/// Sendable so it can be computed off the main actor and handed to the library.
struct MetadataAutoFix: Sendable {
    let id: String
    var title: String?
    var artist: String?
    var album: String?
}

/// Bridges the Core package (SMB/WebDAV file access, recursive scan) to the
/// app's presentation models. Owns source configs, the on-disk media cache, and
/// cache-first playback resolution. Keeps all Core imports in this one file so
/// the App's own `MediaKind`/`CacheState` don't clash with Core's.
actor LibraryService {
    private let cacheDir: URL
    private let artworkDir: URL
    private let streamCacheDir: URL
    private let configsURL: URL
    private let legacyLibraryURL: URL
    private let autoCacheIndexURL: URL
    private let classicalCreditsURL: URL
    private let mediaStore: MediaStore
    private let streamingService = RemoteStreamingService()

    /// Crossfade needs a precise track end on streamed items; the engine flips
    /// this when the crossfade setting changes.
    func setPreferPreciseStreamDuration(_ enabled: Bool) {
        streamingService.preferPreciseDuration = enabled
    }

    private var configs: [SourceConfig] = []
    private var allTracks: [Track] = []
    /// Outcome of the last attempt to load `sources.json`. `.failed` (file
    /// present but unreadable/undecodable) must NEVER be treated as "no sources",
    /// because the orphan-prune / migration paths delete library data for
    /// sources not in `configs`.
    private enum ConfigLoadState { case notLoaded, loaded, failed }
    private var configLoadState: ConfigLoadState = .notLoaded
    private var didLoadLibraryFromDisk = false
    /// Track IDs whose on-disk cache file was produced by the auto-cache /
    /// streaming-promotion path (evictable), as opposed to manual downloads
    /// (pinned). Persisted so the distinction survives refresh/relaunch.
    private var autoCachedIDs: Set<String> = []
    private var didLoadAutoCacheIndex = false
    /// Albums whose cover has been attempted (found OR confirmed absent) this
    /// session, so the artwork backfill doesn't re-hit the server for covers that
    /// aren't there. Cleared on a fresh scan (files may have changed).
    private var attemptedArtworkAlbumIDs: Set<String> = []
    /// True when the most recent scan couldn't list one or more folders (so it
    /// merged rather than pruned). Lets the UI warn the user to rescan on a
    /// stable connection instead of trusting a shrunken count.
    private(set) var lastScanIncomplete = false
    /// old id → new id for files that re-keyed (in-place re-tag/touch) on the last
    /// scan, so AppModel can carry playlists / snapshot / recents / play-stats /
    /// classical credits forward. Empty when nothing re-keyed. Read after `scan`.
    /// Per-source identity remaps from the most recent scan, consumed once by the
    /// caller. Keyed by source so two concurrent rescans can't clobber each
    /// other's remap before AppModel migrates its id-keyed state.
    private var identityRemapsBySource: [String: [String: String]] = [:]

    /// Hand the caller the remap its scan produced (and forget it).
    func takeIdentityRemap(sourceID: String) -> [String: String] {
        identityRemapsBySource.removeValue(forKey: sourceID) ?? [:]
    }
    /// A scan is walking the tree right now. While set, app-background must NOT
    /// tear down the background client — that would interrupt the walk (forcing a
    /// reconnect mid-scan and risking skipped folders).
    private var scanInProgress = false
    /// Background-client reads (downloads, artwork, lyrics) currently in flight.
    /// While >0, app-background must NOT tear down the background client — doing so
    /// mid-download makes the download throw, deletes the `.part`, and returns nil.
    private var inFlightBackgroundOps = 0
    /// In-memory passwords for this session, set on add. Lets the first
    /// add→scan succeed even if the Keychain read lags/fails; Keychain remains
    /// the durable store for relaunches.
    private var sessionPasswords: [String: String] = [:]
    /// Resolved + security-scope-accessing folder URLs for local sources, by id.
    private var localRoots: [String: URL] = [:]
    /// Cached remote clients per sourceID. Building a client is a full
    /// TCP+auth+tree-connect and was previously done on EVERY resolve/stat/
    /// download/artwork call and never torn down — over a session that floods the
    /// server's session table until new connects hang ("does not auto recover").
    /// We keep TWO per source so a whole-file background download (which holds the
    /// client's single op-lock for the entire transfer) can't stall the live
    /// stream: `streamClients` serves playback reads only; `backgroundClients`
    /// serves scan, artwork, and downloads. Torn down on source removal and app
    /// background; each lazily reconnects on its next use.
    private var streamClients: [String: any RemoteFileSystemClient] = [:]
    private var backgroundClients: [String: any RemoteFileSystemClient] = [:]
    /// Album covers resolved from the remote this session (albumID → on-disk URL),
    /// plus in-flight resolutions, so the duplicate `onTrackStarted` +
    /// `loadArtwork` calls for a just-started track (and the backfill) don't each
    /// re-list the folder and re-read embedded art for the same album.
    private var albumArtworkURLCache: [String: URL] = [:]
    private var albumArtworkTasks: [String: Task<(url: URL?, conclusive: Bool), Never>] = [:]
    /// Albums a remote lookup conclusively found NO cover for this session (folder
    /// listed + probe completed, nothing found). Short-circuits the rate-limited
    /// re-list/re-probe/online lookup on every replay. Cleared on rescan.
    private var albumsWithNoRemoteArtwork: Set<String> = []

    init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        // Downloads and album covers must PERSIST across app updates, so they live
        // in Application Support, not Caches — iOS purges Caches under pressure and
        // a reinstall wipes it, which was silently losing every downloaded song and
        // cover on each update. One-time move from the old Caches location so a
        // user's existing downloads/covers survive this transition too. Excluded
        // from iCloud/iTunes backup since both are re-fetchable from the source.
        cacheDir = support.appendingPathComponent("Media", isDirectory: true)
        artworkDir = support.appendingPathComponent("Artwork", isDirectory: true)
        Self.migrateDir(from: caches.appendingPathComponent("Media", isDirectory: true), to: cacheDir, fm: fm)
        Self.migrateDir(from: caches.appendingPathComponent("Artwork", isDirectory: true), to: artworkDir, fm: fm)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        Self.excludeFromBackup(cacheDir)
        Self.excludeFromBackup(artworkDir)
        // Per-session streaming scratch genuinely belongs in Caches (reclaimed each
        // launch below).
        streamCacheDir = caches.appendingPathComponent("StreamingRanges", isDirectory: true)
        try? fm.createDirectory(at: streamCacheDir, withIntermediateDirectories: true)
        configsURL = support.appendingPathComponent("sources.json")
        legacyLibraryURL = support.appendingPathComponent("library.json")
        autoCacheIndexURL = support.appendingPathComponent("autocache.json")
        classicalCreditsURL = support.appendingPathComponent("classical.json")
        mediaStore = MediaStore(configuration: MediaStoreConfiguration(databaseURL: support.appendingPathComponent("library.sqlite")))
    }

    /// Reclaim leaked scratch/temp files. Kept OUT of `init` (which runs on the
    /// MainActor where the service is constructed) — these directory walks are
    /// synchronous file IO and belong on the actor's executor, driven from the
    /// bootstrap task. Idempotent, safe to run once per launch.
    private func reclaimTempFiles() {
        let fm = FileManager.default
        // NOTE: the partial-stream scratch dir is intentionally NOT wiped at launch.
        // The streaming service writes a `<partial>.ranges` sidecar next to each
        // partial and resumes from it on a later session (a 90%-streamed track
        // doesn't refetch from byte 0), so the last-playing track's partial must
        // survive an app kill. The service caps live partials (8) and reclaims its
        // own on teardown; iOS purges this Caches dir under pressure.
        // A crash mid-write can strand a temp in a persistent cache dir: "<uuid>.part"
        // (SMB download destination), "<uuid>.download" (WebDAV/SFTP/FTP stream temp),
        // "<uuid>.art" (remote folder-cover download), or "<uuid>.<ext>.promote" (a
        // stream→cache promotion). All are written in-process — nothing is writing them
        // at launch — and real files are "<hash>.<ext>", so sweep those suffixes from
        // both the media and artwork caches to reclaim the leaked disk.
        let tempSuffixes = [".part", ".download", ".art", ".promote"]
        for dir in [cacheDir, artworkDir] {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in entries where tempSuffixes.contains(where: url.lastPathComponent.hasSuffix) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// One-time relocation of a whole cache directory from its old location to the
    /// new one — only when the new location doesn't exist yet (so it runs once and
    /// never clobbers already-migrated data).
    private static func migrateDir(from old: URL, to new: URL, fm: FileManager) {
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    /// Keep a re-fetchable cache dir out of iCloud/iTunes backups (it persists
    /// locally, it just shouldn't bloat the user's backup).
    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Load

    func bootstrap() -> (configs: [SourceConfig], tracks: [Track]) {
        reclaimTempFiles()
        loadConfigsFromDiskIfNeeded()
        return (configs, [])
    }

    /// Reclaim cache files with no matching track — a removed source, a
    /// clean-rescan-pruned file, or a re-keyed (identity-drifted) orphan. The keep
    /// set is derived from the LIVE library, so this runs ONLY once the library is
    /// loaded and non-empty; never against an empty set (which would wipe the cache).
    /// In-flight download temps ("<uuid>.part"/".download"/".promote") are left to
    /// `reclaimTempFiles`. Callable (launch + a Settings "Reclaim" action).
    func reconcileCacheFiles() {
        guard didLoadLibraryFromDisk, !allTracks.isEmpty else { return }
        loadAutoCacheIndexIfNeeded()
        let fm = FileManager.default
        let keep = Set(allTracks.map { Self.stableHash($0.id) })
        guard let entries = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        let tempSuffixes = [".part", ".download", ".promote"]
        var prunedIndex = false
        for url in entries where !tempSuffixes.contains(where: url.lastPathComponent.hasSuffix) {
            let name = url.lastPathComponent
            let base = name.firstIndex(of: ".").map { String(name[..<$0]) } ?? name
            guard !keep.contains(base) else { continue }
            try? fm.removeItem(at: url)
            // A file removed here can't be identified back to a track id, so drop any
            // auto-cache flag whose file is now gone on the next refresh; also prune
            // flags for ids no longer in the library.
            prunedIndex = true
        }
        if prunedIndex {
            let liveHashes = keep
            let before = autoCachedIDs.count
            autoCachedIDs = autoCachedIDs.filter { liveHashes.contains(Self.stableHash($0)) }
            if autoCachedIDs.count != before { persistAutoCacheIndex() }
        }
    }

    func loadSavedLibrary() async -> [Track] {
        await loadLibraryFromDiskIfNeeded()
        return allTracks
    }

    func refreshCacheSnapshot() async -> [Track] {
        await loadLibraryFromDiskIfNeeded()
        refreshCacheStates()
        return allTracks
    }

    // MARK: Source management

    func addSource(
        name: String,
        proto: String,
        host: String,
        port: Int,
        share: String,
        username: String?,
        domain: String?,
        password: String?,
        rootPath: String
    ) -> SourceConfig {
        loadConfigsFromDiskIfNeeded()
        let id = UUID().uuidString
        if !KeychainStore.set(password, account: id), let password, !password.isEmpty {
            // Keychain write failed — the session password below keeps this launch
            // working, but relaunch will lose the credential. Surface it in the log.
            streamLog.error("keychain set_failed source=\(id, privacy: .public)")
        }
        if let password, !password.isEmpty { sessionPasswords[id] = password }
        let cfg = SourceConfig(
            id: id,
            shareID: UUID().uuidString,
            name: name.isEmpty ? share : name,
            proto: proto,
            host: host,
            port: port,
            share: share,
            username: (username?.isEmpty == false) ? username : nil,
            domain: (domain?.isEmpty == false) ? domain : nil,
            rootPath: rootPath.isEmpty ? "/" : rootPath
        )
        configs.append(cfg)
        persistConfigs()
        return cfg
    }

    /// Add an on-device / Files / iCloud folder as a source. `bookmark` is a
    /// base64 security-scoped bookmark created by the caller from the picked URL.
    func addLocalSource(name: String, bookmark: String, displayPath: String) -> SourceConfig {
        loadConfigsFromDiskIfNeeded()
        let cfg = SourceConfig(
            id: UUID().uuidString,
            shareID: UUID().uuidString,
            name: name.isEmpty ? "Local Music" : name,
            proto: SourceProtocol.local.rawValue,
            host: "",
            port: 0,
            share: (displayPath as NSString).lastPathComponent,
            username: nil,
            domain: nil,
            rootPath: displayPath,
            bookmark: bookmark
        )
        configs.append(cfg)
        persistConfigs()
        return cfg
    }

    func removeSource(_ id: String) async {
        await loadLibraryFromDiskIfNeeded()
        await disconnectClients(for: id)
        if let url = localRoots[id] {
            url.stopAccessingSecurityScopedResource()
            localRoots[id] = nil
        }
        // Delete the source's on-disk cache files (and drop their auto-cache flags)
        // BEFORE the tracks leave `allTracks` — once they're gone nothing can map the
        // "<hash>.<ext>" filenames back, and the bytes would leak until reinstall.
        loadAutoCacheIndexIfNeeded()
        let fm = FileManager.default
        var prunedIndex = false
        for track in allTracks where track.sourceID == id {
            try? fm.removeItem(at: cacheFileURL(for: track))
            if autoCachedIDs.remove(track.id) != nil { prunedIndex = true }
        }
        if prunedIndex { persistAutoCacheIndex() }
        configs.removeAll { $0.id == id }
        allTracks.removeAll { $0.sourceID == id }
        KeychainStore.delete(account: id)
        persistConfigs()
        if let sourceID = UUID(uuidString: id).map(SourceID.init(rawValue:)) {
            try? await mediaStore.deleteMediaItems(sourceID: sourceID)
        }
    }

    func configList() -> [SourceConfig] {
        loadConfigsFromDiskIfNeeded()
        return configs
    }

    #if DEBUG
    func debugSetSessionPassword(_ password: String, sourceID: String) {
        sessionPasswords[sourceID] = password
    }
    #endif

    // MARK: Scan

    private static let scanDirFilter = LibraryScanFilter()
    /// Download-manager working dirs whose contents are duplicates-in-flight.
    private static let skippedStagingDirNames: Set<String> = ["_slskd_staging"]

    /// Live scan telemetry streamed to the caller so the Sources card's songs /
    /// folders / size metrics can tick up in real time while the walk runs.
    struct ScanTick: Sendable {
        var files: Int
        var folders: Int
        var bytes: Int64
    }

    /// Recursively scan a source into tracks (path-first). Returns the full
    /// merged library so the caller can replace its state.
    func scan(sourceID: String, progress: (@Sendable (ScanTick) -> Void)? = nil) async throws -> [Track] {
        await loadLibraryFromDiskIfNeeded()
        guard let cfg = configs.first(where: { $0.id == sourceID }) else { return allTracks }
        scanInProgress = true
        defer { scanInProgress = false }

        if cfg.proto == SourceProtocol.local.rawValue {
            let scanned = try await scanLocal(cfg)
            allTracks.removeAll { $0.sourceID == cfg.id }
            allTracks.append(contentsOf: scanned)
            refreshCacheStates()
            await persistLibrary(sourceID: cfg.id, tracks: scanned)
            return allTracks
        }

        guard let client = backgroundClient(for: cfg) else {
            throw LibraryError(kind: .other, message: "This source is missing connection details.")
        }

        // Tolerant recursive walk. The Core RemoteLibraryScanner aborts the whole
        // scan if any single folder fails to list (perms/system dirs), which made
        // real shares show as Unavailable. Here a deep folder failure is skipped;
        // only a failure on the FIRST (root) list is treated as a real connection
        // error and surfaced.
        // Incremental: reuse tracks for unchanged files. `stableKey` encodes size
        // + modified-time, so an unchanged file produces the same id and we skip
        // its metadata probe entirely (a rescan of an unchanged library is then
        // near-instant). Reused tracks keep their existing artwork. Artwork for
        // NEW/changed files is left to the post-scan backfill so the scan's hot
        // path is just cheap metadata probes — no multi-MB cover reads inline,
        // which is what made a full scan look like it hung "forever".
        // Reuse key is path|size|seconds — tolerant of sub-second / storage
        // precision differences in modified-time (keying on the ms-precision
        // stableKey could silently mismatch and re-probe the whole library).
        func reuseKey(path: String, size: Int64?, modifiedEpoch: Double?) -> String {
            let normalized = RemotePath(displayPath: path).normalizedPath
            return "\(normalized)|\(size ?? -1)|\(Int(modifiedEpoch ?? 0))"
        }
        let existing = Dictionary(
            allTracks.filter { $0.sourceID == sourceID }.map {
                (reuseKey(path: $0.remotePath ?? $0.folderPath, size: $0.sizeBytes, modifiedEpoch: $0.modifiedAtEpoch), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        attemptedArtworkAlbumIDs.removeAll()   // re-attempt covers after a scan
        albumArtworkURLCache.removeAll()       // files may have changed; re-resolve
        albumsWithNoRemoteArtwork.removeAll()  // a cover may have been added

        let classifier = MediaFileClassifier()
        var scanned: [Track] = []
        var pending: [RemotePath] = [RemotePath(displayPath: cfg.rootPath)]
        var visited = Set<String>()
        var listedAnyFolder = false
        // Number of folders we COULD NOT list this pass (after a retry). While
        // >0 the walk is incomplete, so we must NOT prune un-seen tracks below —
        // doing so silently wipes folders we simply failed to read (a flaky
        // connection or an unlistable folder), which is how a rescan can shrink
        // the library from 20 GB to 10 GB.
        var listFailures = 0
        var filesSeen = 0
        var bytesSeen: Int64 = 0
        // Newly-probed tracks since the last mid-scan checkpoint. Deep-folder
        // failures and cancellation already keep partial results, but an app
        // kill / crash / hard client throw used to lose the whole pass — a 10k
        // first scan on flaky Wi-Fi could restart from zero repeatedly.
        var newSinceCheckpoint: [Track] = []
        #if DEBUG
        AppLog.library.debug("BETTERSTREAMING_SCAN start source=\(sourceID, privacy: .public) root=\(cfg.rootPath) priorTracks=\(existing.count)")
        #endif

        while let dir = pending.popLast() {
            if Task.isCancelled { break }
            if visited.contains(dir.normalizedPath) { continue }
            visited.insert(dir.normalizedPath)

            let entries: [RemoteEntry]
            do {
                entries = try await client.list(dir)
                listedAnyFolder = true
            } catch {
                if !listedAnyFolder { throw Self.libraryError(from: error) }
                // Retry a couple of times: a wedged op tears down + reconnects the
                // client, so a transient stall usually clears within a retry or
                // two. Only count a failure (→ suppress pruning) if all retries
                // fail, so a flaky connection can't drop a folder's tracks.
                var recovered: [RemoteEntry]?
                for _ in 0..<2 {
                    if let r = try? await client.list(dir) { recovered = r; break }
                }
                if let recovered {
                    listedAnyFolder = true
                    entries = recovered
                } else {
                    listFailures += 1
                    #if DEBUG
                    AppLog.library.error("BETTERSTREAMING_SCAN list_failed dir=\(dir.displayPath) err=\(error, privacy: .public)")
                    #endif
                    continue
                }
            }

            #if DEBUG
            let dirCount = entries.filter { $0.kind == .directory }.count
            let fileCount = entries.filter { $0.kind == .file }.count
            AppLog.library.debug("BETTERSTREAMING_SCAN dir=\(dir.displayPath) entries=\(entries.count) dirs=\(dirCount) files=\(fileCount)")
            #endif

            // Split this folder's entries: queue subfolders inline, collect media
            // files in entry order. A reused (unchanged) file carries its prior track
            // for free; a NEW file needs a 256KB head probe + parse.
            var dirFiles: [(entry: RemoteEntry, kind: IndexedMediaKind, prior: Track?)] = []
            for entry in entries {
                if Task.isCancelled { break }
                switch entry.kind {
                case .directory:
                    // Junk/system dirs (#recycle, @eaDir, dot-dirs) and download
                    // staging must not be indexed — a stray slskd incomplete/ file
                    // showed up as a duplicate 1-song album. The package filter
                    // existed but this walk never called it.
                    guard Self.scanDirFilter.shouldDescendIntoDirectoryName(entry.name),
                          !Self.skippedStagingDirNames.contains(entry.name.lowercased()) else { break }
                    if visited.count + pending.count < 50_000 { pending.append(entry.path) }
                case .file:
                    guard let kind = classifier.classify(entry), scanned.count + dirFiles.count < 100_000 else { break }
                    let key = reuseKey(path: entry.path.displayPath, size: entry.size, modifiedEpoch: entry.modifiedAt?.timeIntervalSince1970)
                    dirFiles.append((entry, kind, existing[key]))
                default:
                    break
                }
            }

            // Probe the NEW files with bounded concurrency (width 4) so their head
            // reads overlap on the wire, then splice results back into the original
            // entry order. SMB serializes ops on its own lock (only the parse
            // overlaps there); WebDAV/SFTP/FTP genuinely overlap the reads. A nil
            // probe still yields a filename-inferred track, exactly as before.
            var resolved = [Track?](repeating: nil, count: dirFiles.count)
            var toProbe: [Int] = []
            for i in dirFiles.indices {
                if let prior = dirFiles[i].prior {
                    resolved[i] = prior   // unchanged — no re-probe, keep artwork
                } else {
                    toProbe.append(i)
                }
            }
            // Collect inside the group closure and return, instead of mutating a
            // captured local — region isolation forbids reusing a var after it's
            // been sent into the group.
            let probeIndices = toProbe
            let probed: [(Int, Track)] = try await withThrowingTaskGroup(of: (Int, Track).self) { group in
                var out: [(Int, Track)] = []
                out.reserveCapacity(probeIndices.count)
                var cursor = 0
                func scheduleNext() {
                    guard cursor < probeIndices.count else { return }
                    let i = probeIndices[cursor]
                    cursor += 1
                    let entry = dirFiles[i].entry
                    let kind = dirFiles[i].kind
                    group.addTask { [self] in
                        let ext = (entry.name as NSString).pathExtension
                        let probe = await self.embeddedProbe(for: entry, client: client)
                        let embedded = await self.parsedEmbedded(entry: entry, client: client, probe: probe, ext: ext)
                        let t = await self.track(fromEntry: entry, kind: kind, cfg: cfg, embedded: embedded)
                        return (i, t)
                    }
                }
                for _ in 0..<4 { scheduleNext() }
                while let pair = try await group.next() {
                    out.append(pair)
                    scheduleNext()
                }
                return out
            }
            for (i, track) in probed { resolved[i] = track }
            for track in resolved {
                guard let track else { continue }
                scanned.append(track)
                filesSeen += 1
                bytesSeen += track.sizeBytes ?? 0
                if filesSeen % 20 == 0 {
                    progress?(ScanTick(files: filesSeen, folders: visited.count, bytes: bytesSeen))
                }
            }

            // Checkpoint: durably upsert freshly-probed tracks every ~500 (non-
            // destructive, no prune — the end-of-scan replace stays the source of
            // truth). After an interruption, the relaunch loads these rows and the
            // next scan's reuse map skips re-probing them.
            newSinceCheckpoint.append(contentsOf: probed.map(\.1))
            if newSinceCheckpoint.count >= 500 {
                let batch = newSinceCheckpoint
                newSinceCheckpoint.removeAll()
                _ = try? await mediaStore.upsertMediaItems(batch.map(mediaItem(from:)))
                #if DEBUG
                AppLog.library.debug("BETTERSTREAMING_SCAN checkpoint persisted=\(batch.count)")
                #endif
            }
        }

        progress?(ScanTick(files: filesSeen, folders: visited.count, bytes: bytesSeen))

        // Only a CLEAN walk (every folder listed) may prune: replacing with
        // `scanned` deletes any prior track not re-seen. On a partial walk, merge
        // instead — keep prior tracks we didn't re-scan so skipped folders survive.
        // (Genuinely-deleted files are pruned on the next clean scan.)
        #if DEBUG
        AppLog.library.debug("BETTERSTREAMING_SCAN done visited=\(visited.count) filesSeen=\(filesSeen) scanned=\(scanned.count) listFailures=\(listFailures) cancelled=\(Task.isCancelled)")
        #endif
        // Cancelled mid-walk → `scanned` is partial. NEVER persist it (that would
        // replace the library with a half-walk and prune the rest). Leave the
        // library untouched.
        if Task.isCancelled {
            lastScanIncomplete = true
            return allTracks
        }
        lastScanIncomplete = listFailures > 0
        var merged: [Track]
        if listFailures == 0 {
            merged = scanned
        } else {
            let scannedIDs = Set(scanned.map(\.id))
            let priorKept = allTracks.filter { $0.sourceID == sourceID && !scannedIDs.contains($0.id) }
            merged = scanned + priorKept
            streamLog.error("scan partial sourceID=\(sourceID, privacy: .public) listFailures=\(listFailures) scanned=\(scanned.count) kept=\(priorKept.count)")
        }

        let oldForSource = allTracks.filter { $0.sourceID == sourceID }
        identityRemapsBySource[sourceID] = await applyIdentityRemap(old: oldForSource, new: &merged)

        allTracks.removeAll { $0.sourceID == sourceID }
        allTracks.append(contentsOf: merged)
        refreshCacheStates()
        await persistLibrary(sourceID: sourceID, tracks: merged)
        reconcileCacheFiles()   // reclaim files for tracks this scan pruned/re-keyed
        return allTracks
    }

    /// Conservative identity re-key map for a rescan: old id → new id for every new
    /// id whose path-stable prefix matches EXACTLY ONE non-surviving old id (and one
    /// new id). An in-place re-tag/touch mints a fresh stableKey for the same file;
    /// this carries it forward. Ambiguous (0 or >1 match) → no remap. Pure/testable.
    nonisolated static func identityRemap(oldIDs: [String], newIDs: [String]) -> [String: String] {
        let oldSet = Set(oldIDs), newSet = Set(newIDs)
        var oldByPrefix: [String: [String]] = [:]
        for id in oldIDs where !newSet.contains(id) {
            guard let p = MediaStore.pathStablePrefix(ofStableKey: id) else { continue }
            oldByPrefix[p, default: []].append(id)
        }
        var newByPrefix: [String: [String]] = [:]
        for id in newIDs where !oldSet.contains(id) {
            guard let p = MediaStore.pathStablePrefix(ofStableKey: id) else { continue }
            newByPrefix[p, default: []].append(id)
        }
        var remap: [String: String] = [:]
        for (prefix, olds) in oldByPrefix where olds.count == 1 {
            guard let news = newByPrefix[prefix], news.count == 1 else { continue }
            remap[olds[0]] = news[0]
        }
        return remap
    }

    /// Carry base-row state (favorite, duration, artwork) from each re-keyed old
    /// track onto its new track, rename the cache file to the new hash (keeping
    /// cacheState), move the auto-cache flag, and rewrite the DB override key.
    /// Returns the old→new map for AppModel to migrate its own id-keyed state.
    private func applyIdentityRemap(old: [Track], new merged: inout [Track]) async -> [String: String] {
        let remap = Self.identityRemap(oldIDs: old.map(\.id), newIDs: merged.map(\.id))
        guard !remap.isEmpty else { return [:] }
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newToOld = Dictionary(remap.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        loadAutoCacheIndexIfNeeded()
        let fm = FileManager.default
        var autoChanged = false
        for i in merged.indices {
            guard let oldID = newToOld[merged[i].id], let prior = oldByID[oldID] else { continue }
            merged[i].isFavorite = prior.isFavorite
            if merged[i].durationSeconds <= 0, prior.durationSeconds > 0 { merged[i].durationSeconds = prior.durationSeconds }
            if merged[i].artworkURL == nil { merged[i].artworkURL = prior.artworkURL }
            let oldURL = Self.cacheFileURL(for: prior, cacheDir: cacheDir)
            let newURL = Self.cacheFileURL(for: merged[i], cacheDir: cacheDir)
            if fm.fileExists(atPath: oldURL.path), !fm.fileExists(atPath: newURL.path) {
                try? fm.moveItem(at: oldURL, to: newURL)
            }
            if autoCachedIDs.remove(oldID) != nil { autoCachedIDs.insert(merged[i].id); autoChanged = true }
        }
        if autoChanged { persistAutoCacheIndex() }
        try? await mediaStore.remapMetadataOverrides(remap)
        return remap
    }

    private func entryIdentity(_ entry: RemoteEntry, cfg: SourceConfig) -> RemoteItemIdentity {
        RemoteItemIdentity(
            sourceID: SourceID(rawValue: UUID(uuidString: cfg.id) ?? UUID()),
            shareID: ShareID(rawValue: UUID(uuidString: cfg.shareID) ?? UUID()),
            path: entry.path,
            remoteFileID: entry.fileID,
            size: entry.size,
            modifiedAt: entry.modifiedAt
        )
    }

    private func track(
        fromEntry entry: RemoteEntry,
        kind: IndexedMediaKind,
        cfg: SourceConfig,
        embedded: EmbeddedMediaMetadata? = nil
    ) -> Track {
        let identity = entryIdentity(entry, cfg: cfg)
        let metadata = Self.resolvedTrackMetadata(
            fileName: entry.name,
            pathComponents: entry.path.remotePathComponents,
            rootComponents: RemotePath(displayPath: cfg.rootPath).remotePathComponents,
            sourceName: cfg.name,
            embedded: embedded
        )
        return Track(
            id: identity.stableKey,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            // albumID/artistID derived from folder + feat-stripped artist by the
            // Track initializer (see MetadataGrouping) — do not key on raw artist.
            genre: metadata.genre,
            durationSeconds: metadata.durationSeconds,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            kind: kind == .audio ? .audio : .video,
            cacheState: .remoteOnly,
            sourceID: cfg.id,
            sourceName: cfg.name,
            folderPath: entry.path.displayPath,
            shareID: cfg.shareID,
            remotePath: entry.path.displayPath,
            sizeBytes: entry.size,
            modifiedAtEpoch: entry.modifiedAt?.timeIntervalSince1970
        )
    }

    /// Small ranged read from the start of a remote file, for tag + artwork
    /// parsing during scan (256KB by default).
    private func embeddedProbe(for entry: RemoteEntry, client: any RemoteFileSystemClient) async -> Data? {
        guard client.capabilities.supportsByteRangeRead else { return nil }
        var size = entry.size
        if size == nil {
            size = (try? await client.stat(entry.path))?.size
        }
        guard let size, size > 0 else { return nil }
        let readLength = min(size, Int64(EmbeddedMetadataReader.defaultProbeLength))
        guard readLength > 0 else { return nil }
        return try? await client.read(entry.path, range: 0..<readLength)
    }

    /// Parse embedded tags from a head probe, with a moov-at-end fallback for
    /// MP4/M4A files (non-faststart): when the head yields nothing, derive the
    /// trailing-`moov` byte range, ranged-read just that region, and merge. Bounded
    /// so a pathological layout can't pull the whole file.
    private func parsedEmbedded(
        entry: RemoteEntry,
        client: any RemoteFileSystemClient,
        probe: Data?,
        ext: String
    ) async -> EmbeddedMediaMetadata? {
        guard let probe else { return nil }
        let head = EmbeddedMetadataReader.parse(probe, fileExtension: ext)
        if !head.isEmpty { return head }
        guard client.capabilities.supportsByteRangeRead else { return nil }
        var size = entry.size
        if size == nil { size = (try? await client.stat(entry.path))?.size }
        guard let size, size > 0,
              let tailRange = EmbeddedMetadataReader.mp4MetadataTailRange(head: [UInt8](probe), fileLength: size),
              tailRange.upperBound > tailRange.lowerBound,
              tailRange.upperBound - tailRange.lowerBound <= 8 * 1_024 * 1_024,
              let tail = try? await client.read(entry.path, range: tailRange) else { return nil }
        let merged = EmbeddedMetadataReader.parse(head: probe, tail: tail, fileExtension: ext)
        return merged.isEmpty ? nil : merged
    }

    /// Extract embedded album art from a remote file. The 256KB probe often does
    /// NOT contain a hi-res cover (e.g. FLAC PICTURE blocks can be 0.5–2MB), so:
    ///  1. use art already present in the probe, else
    ///  2. for FLAC, read the PICTURE block's exact byte range (from its header), else
    ///  3. fall back to one larger bounded read (ID3 APIC / MP4 covr past the probe).
    private func remoteArtwork(
        entry: RemoteEntry,
        client: any RemoteFileSystemClient,
        probe: Data?,
        ext: String
    ) async -> EmbeddedArtwork? {
        if let probe, let art = EmbeddedMetadataReader.parse(probe, fileExtension: ext).artwork {
            return art
        }
        guard client.capabilities.supportsByteRangeRead else { return nil }
        let probeBytes = probe.map { [UInt8]($0) } ?? []

        if let range = EmbeddedMetadataReader.artworkByteRange(probe: probeBytes, fileExtension: ext) {
            let lower = Int64(range.lowerBound)
            let upper = Int64(range.upperBound)
            if upper > lower, upper - lower <= 12 * 1_024 * 1_024,
               let data = try? await client.read(entry.path, range: lower..<upper) {
                return EmbeddedMetadataReader.parseFLACPicture([UInt8](data))
            }
        }

        // Other containers: a larger bounded read from the start.
        var size = entry.size
        if size == nil { size = (try? await client.stat(entry.path))?.size }
        if let size {
            let bigLen = min(size, 4 * 1_024 * 1_024)
            if bigLen > Int64(probe?.count ?? 0),
               let data = try? await client.read(entry.path, range: 0..<bigLen) {
                return EmbeddedMetadataReader.parse(data, fileExtension: ext).artwork
            }
        }
        return nil
    }

    struct ResolvedTrackMetadata {
        var title: String
        var artist: String
        var album: String
        var genre: String
        var durationSeconds: Double
        var trackNumber: Int?
        var discNumber: Int?
    }

    nonisolated static func resolvedTrackMetadata(
        fileName: String,
        pathComponents: [String],
        rootComponents: [String],
        sourceName: String,
        embedded: EmbeddedMediaMetadata?
    ) -> ResolvedTrackMetadata {
        let stem = (fileName as NSString).deletingPathExtension
        let parsed = parseTrack(stem)
        let relative = relativeComponents(pathComponents: pathComponents, rootComponents: rootComponents)
        let folders = relative.dropLast()
        let fallbackAlbum = cleanMetadataValue(folders.last) ?? sourceName
        let fallbackArtist = fallbackArtist(folders: Array(folders), rootComponents: rootComponents)

        // An embedded TITLE tag is authoritative — use it verbatim. Running it
        // through parseTrack stripped a leading 1-3 digit run ("99 Problems" →
        // "Problems", "7 Years" → "Years") and stole it as a track number. Only
        // filenames need number-stripping.
        let embeddedTitle = cleanMetadataValue(embedded?.title)
        // Recover "Artist - Title" from the file name when tags are missing —
        // common for downloads stored as ".../NN - Artist - Title.ext" inside a
        // junk username folder, where the real artist would otherwise be lost.
        let fromName = splitArtistTitle(parsed.title)
        let title = embeddedTitle
            ?? fromName.title
            ?? (parsed.title.isEmpty ? fileName : parsed.title)
        let artist = cleanMetadataValue(embedded?.artist)
            ?? fromName.artist
            ?? fallbackArtist
        let album = cleanMetadataValue(embedded?.album) ?? fallbackAlbum
        let genre = cleanMetadataValue(embedded?.genre) ?? "Unknown"
        let duration = embedded?.durationSeconds ?? 0

        return ResolvedTrackMetadata(
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            durationSeconds: duration,
            trackNumber: embedded?.trackNumber ?? parsed.number,
            discNumber: embedded?.discNumber
        )
    }

    nonisolated private static func relativeComponents(pathComponents: [String], rootComponents: [String]) -> [String] {
        var offset = 0
        let maxOffset = min(pathComponents.count, rootComponents.count)
        while offset < maxOffset,
              pathComponents[offset].localizedCaseInsensitiveCompare(rootComponents[offset]) == .orderedSame {
            offset += 1
        }
        return Array(pathComponents.dropFirst(offset))
    }

    nonisolated private static func fallbackArtist(folders: [String], rootComponents: [String]) -> String {
        guard folders.count >= 2,
              let artist = cleanMetadataValue(folders[folders.count - 2]) else {
            return "Unknown Artist"
        }
        if let rootName = rootComponents.last,
           artist.localizedCaseInsensitiveCompare(rootName) == .orderedSame {
            return "Unknown Artist"
        }
        return artist
    }

    nonisolated private static func cleanMetadataValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\u{0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    nonisolated private static func isFolderCover(_ entry: RemoteEntry) -> Bool {
        guard entry.kind == .file else { return false }
        return folderCoverNames.contains(entry.name.lowercased())
    }

    nonisolated private static let folderCoverNames: Set<String> = [
        "cover.jpg", "cover.jpeg", "cover.png",
        "folder.jpg", "folder.jpeg", "folder.png",
        "front.jpg", "front.jpeg", "front.png",
        "album.jpg", "album.jpeg", "album.png",
        "albumart.jpg", "albumart.jpeg", "albumart.png"
    ]

    private static func libraryError(from error: Error) -> LibraryError {
        if let rfs = error as? RemoteFileSystemError {
            switch rfs {
            case .authenticationExpired, .permissionDenied:
                return LibraryError(kind: .auth, message: "Sign-in failed. Check the username and password.")
            case .notFound:
                return LibraryError(kind: .notFound, message: "The share or folder wasn’t found.")
            case .timeout, .serverDisconnected:
                return LibraryError(kind: .unreachable, message: rfs.userMessage)
            default:
                return LibraryError(kind: .other, message: rfs.userMessage)
            }
        }
        return LibraryError(kind: .other, message: error.localizedDescription)
    }

    // MARK: Playback resolution (cache-first)

    func playableItem(for track: Track, offline: Bool) async -> AVPlayerItem? {
        loadConfigsFromDiskIfNeeded()
        if let localURL = localFileURL(for: track) ?? cachedFileURLIfPresent(for: track) {
            #if DEBUG
            AppLog.cache.debug("BETTERSTREAMING_RESOLVE local_or_cached title=\(track.title) url=\(localURL.path)")
            #endif
            // Precise timing: forces AVFoundation to compute the true duration by
            // scanning frame headers instead of estimating from bitrate. VBR MP3s
            // (e.g. without an accurate Xing header) otherwise report a duration
            // seconds short of the real audio — which made the crossfade fade out
            // early and the clock run past the end.
            let asset = AVURLAsset(url: localURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            return AVPlayerItem(asset: asset)
        }
        if offline { return nil }
        guard let cfg = configs.first(where: { $0.id == track.sourceID }),
              let client = streamClient(for: cfg) else {
            let hasConfig = configs.contains(where: { $0.id == track.sourceID })
            streamLog.error("resolve no_client title=\(track.title, privacy: .public) hasConfig=\(hasConfig)")
            return nil
        }
        streamLog.info("resolve start title=\(track.title, privacy: .public)")

        let identity = remoteIdentity(for: track, cfg: cfg)
        guard client.capabilities.supportsByteRangeRead else {
            #if DEBUG
            AppLog.cache.debug("BETTERSTREAMING_RESOLVE full_download_fallback no_range title=\(track.title)")
            #endif
            guard let url = await playableURL(for: track, offline: false) else { return nil }
            return AVPlayerItem(url: url)
        }

        do {
            let metadata = try await client.stat(identity.path)
            guard metadata.kind == .file,
                  let size = metadata.size,
                  size > 0,
                  metadata.supportsRangeRead else {
                #if DEBUG
                AppLog.cache.debug("BETTERSTREAMING_RESOLVE full_download_fallback stat title=\(track.title) kind=\(String(describing: metadata.kind), privacy: .public) size=\(metadata.size ?? -1) range=\(metadata.supportsRangeRead)")
                #endif
                guard let url = await playableURL(for: track, offline: false) else { return nil }
                return AVPlayerItem(url: url)
            }
            streamLog.info("resolve streaming title=\(track.title, privacy: .public) size=\(size)")
            let streamMetadata = RemoteMetadata(
                path: metadata.path,
                kind: metadata.kind,
                size: size,
                modifiedAt: metadata.modifiedAt,
                fileID: metadata.fileID,
                contentType: metadata.contentType,
                supportsRangeRead: metadata.supportsRangeRead
            )
            let trackID = track.id
            return streamingService.playerItem(
                client: client,
                path: identity.path,
                metadata: streamMetadata,
                fallbackExtension: track.fileExtension,
                partialCacheURL: streamCacheFileURL(for: track),
                completeCacheURL: cacheFileURL(for: track),
                onComplete: { [weak self] in await self?.onStreamFullyCached(trackID) },
                onTeardown: { [weak self] in await self?.onStreamSessionTornDown(trackID) }
            )
        } catch {
            streamLog.error("resolve stat_error title=\(track.title, privacy: .public) err=\(String(describing: error), privacy: .public)")
            guard let url = await playableURL(for: track, offline: false) else { return nil }
            return AVPlayerItem(url: url)
        }
    }

    func playableURL(for track: Track, offline: Bool) async -> URL? {
        loadConfigsFromDiskIfNeeded()
        if let localURL = localFileURL(for: track) { return localURL }   // local source: play in place
        if let local = cachedFileURLIfPresent(for: track) { return local }
        if offline { return nil }
        guard let cfg = configs.first(where: { $0.id == track.sourceID }),
              let client = backgroundClient(for: cfg) else { return nil }
        inFlightBackgroundOps += 1
        defer { inFlightBackgroundOps -= 1 }

        let identity = remoteIdentity(for: track, cfg: cfg)
        let local = cacheFileURL(for: track)
        let tmp = cacheDir.appendingPathComponent(UUID().uuidString + ".part")
        do {
            try await client.download(identity.path, to: tmp, progress: nil)
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: tmp, to: local)
            applyPlaybackFileProtection(local)
            return local
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
    }

    /// Force-download. `auto: true` for auto-cache/prefetch (evictable);
    /// `auto: false` for a manual download/pin (kept until the user removes it).
    /// Returns true if the file is on disk afterwards.
    @discardableResult
    func ensureCached(_ track: Track, auto: Bool = false) async -> Bool {
        if isCached(track) {
            updateAutoCacheMembership(track.id, auto: auto)
            return true
        }
        let ok = await playableURL(for: track, offline: false) != nil
        if ok { updateAutoCacheMembership(track.id, auto: auto) }
        return ok
    }

    func evict(_ track: Track) {
        try? FileManager.default.removeItem(at: cacheFileURL(for: track))
        unmarkAutoCached(track.id)
    }

    /// Fired (off-actor, Sendable) when a track finishes streaming fully to disk, so
    /// AppModel can flip its in-memory cache state immediately instead of waiting for
    /// the next play/relaunch. Set by AppModel via `setStreamCacheCallback`.
    private var onTrackFullyCached: (@Sendable (String) -> Void)?

    func setStreamCacheCallback(_ callback: @escaping @Sendable (String) -> Void) {
        onTrackFullyCached = callback
    }

    /// Called by the streaming service once a track has been fully streamed and
    /// copied into the media cache. Treated as an (evictable) auto-cache entry.
    func onStreamFullyCached(_ id: String) {
        liveStreamTrackIDs.remove(id)
        markAutoCached(id)
        applyPlaybackFileProtectionForCached(id)
        refreshCacheStates()
        onTrackFullyCached?(id)
    }

    /// Called when a stream session is torn down (skip / LRU eviction) without
    /// completing: release the track's deterministic partial-file name so the
    /// next play of it can resume from the `.ranges` sidecar again.
    func onStreamSessionTornDown(_ id: String) {
        liveStreamTrackIDs.remove(id)
    }

    // MARK: Auto-cache index (evictable vs pinned)

    private func loadAutoCacheIndexIfNeeded() {
        guard !didLoadAutoCacheIndex else { return }
        didLoadAutoCacheIndex = true
        if let data = try? Data(contentsOf: autoCacheIndexURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            autoCachedIDs = Set(decoded)
        }
    }

    private func persistAutoCacheIndex() {
        if let data = try? JSONEncoder().encode(Array(autoCachedIDs)) {
            try? data.write(to: autoCacheIndexURL, options: .atomic)
        }
    }

    // MARK: Classical credits overlay (MusicBrainz + OpenOpus, keyed by track id)

    func loadClassicalCredits() -> [String: ClassicalCredits] {
        guard let data = try? Data(contentsOf: classicalCreditsURL),
              let decoded = try? JSONDecoder().decode([String: ClassicalCredits].self, from: data) else { return [:] }
        // Prune credits whose track is gone (removed source / NAS drift), so the
        // file doesn't grow unbounded. Match by exact id (covers local ids) OR the
        // path-stable prefix (so an identity re-key doesn't orphan a live credit).
        // Skip pruning until the library is actually loaded — never wipe against an
        // empty set at cold bootstrap.
        guard didLoadLibraryFromDisk, !allTracks.isEmpty else { return decoded }
        let liveIDs = Set(allTracks.map(\.id))
        let livePrefixes = Set(allTracks.compactMap { MediaStore.pathStablePrefix(ofStableKey: $0.id) })
        let pruned = decoded.filter { key, _ in
            liveIDs.contains(key) || (MediaStore.pathStablePrefix(ofStableKey: key).map(livePrefixes.contains) ?? false)
        }
        if pruned.count != decoded.count { saveClassicalCredits(pruned) }
        return pruned
    }

    func saveClassicalCredits(_ credits: [String: ClassicalCredits]) {
        if let data = try? JSONEncoder().encode(credits) {
            try? data.write(to: classicalCreditsURL, options: .atomic)
        }
    }

    private func markAutoCached(_ id: String) {
        loadAutoCacheIndexIfNeeded()
        if autoCachedIDs.insert(id).inserted { persistAutoCacheIndex() }
    }

    private func unmarkAutoCached(_ id: String) {
        loadAutoCacheIndexIfNeeded()
        if autoCachedIDs.remove(id) != nil { persistAutoCacheIndex() }
    }

    /// Manual download pins; auto-cache keeps stay evictable.
    private func updateAutoCacheMembership(_ id: String, auto: Bool) {
        if auto { markAutoCached(id) } else { unmarkAutoCached(id) }
    }

    private func applyPlaybackFileProtectionForCached(_ id: String) {
        guard let track = allTracks.first(where: { $0.id == id }) else { return }
        applyPlaybackFileProtection(cacheFileURL(for: track))
    }

    func isCached(_ track: Track) -> Bool {
        FileManager.default.fileExists(atPath: cacheFileURL(for: track).path)
    }

    func cachedBytes() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return urls.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sum + Int64(size)
        }
    }

    /// Bytes used by evictable auto-cache files only (excludes manual pins and
    /// local sources), so the "X of Y" budget readout reflects the auto hot set.
    func autoCachedBytes() -> Int64 {
        loadAutoCacheIndexIfNeeded()
        let sizesByHash = cacheFileSizesByHash()
        var total: Int64 = 0
        for track in allTracks where autoCachedIDs.contains(track.id) {
            if let size = sizesByHash[Self.stableHash(track.id)] { total += Int64(size) }
        }
        return total
    }

    /// Embedded artwork for a cached file, for Now Playing / lock screen.
    func artworkData(for track: Track) async -> Data? {
        let local = localFileURL(for: track) ?? cacheFileURL(for: track)
        guard FileManager.default.fileExists(atPath: local.path) else { return nil }
        let asset = AVURLAsset(url: local)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }

    /// Fetch lyrics for a track: a `.lrc` sidecar (same path, `.lrc` extension)
    /// from the source — synced if it carries timestamps — else nil. Bounded read
    /// (lyrics files are tiny).
    func lyrics(for track: Track, offline: Bool = false) async -> [LyricsLine]? {
        loadConfigsFromDiskIfNeeded()
        func parse(_ data: Data) -> [LyricsLine]? {
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            guard let text else { return nil }
            let lines = LyricsParser.parse(text)
            return lines.isEmpty ? nil : lines
        }
        // Local source: read the sidecar straight off disk (works offline).
        if let localURL = localFileURL(for: track) {
            let lrc = localURL.deletingPathExtension().appendingPathExtension("lrc")
            if let data = try? Data(contentsOf: lrc) { return parse(data) }
            return nil
        }
        // Remote sidecar fetch dials the source — skip it in Offline Mode.
        if offline { return nil }
        guard let cfg = configs.first(where: { $0.id == track.sourceID }),
              cfg.proto != SourceProtocol.local.rawValue,
              let client = backgroundClient(for: cfg),
              let remote = track.remotePath, !remote.isEmpty else { return nil }
        inFlightBackgroundOps += 1
        defer { inFlightBackgroundOps -= 1 }
        let lrcPath = RemotePath(displayPath: (remote as NSString).deletingPathExtension + ".lrc")
        guard let meta = try? await client.stat(lrcPath), meta.kind == .file,
              let size = meta.size, size > 0, size < 1_000_000,
              let data = try? await client.read(lrcPath, range: 0..<size) else { return nil }
        return parse(data)
    }

    /// Extract embedded artwork from a locally-available track and cache a
    /// shared thumbnail per album. Returns the cached file URL (or nil).
    func cacheAlbumArtwork(for track: Track) async -> URL? {
        let dest = artworkDir.appendingPathComponent(Self.stableHash(track.albumID) + ".jpg")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let data = await artworkData(for: track) else { return nil }
        try? data.write(to: dest, options: .atomic)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
    }

    /// Online artist photo, cached to the (persisted) artwork dir keyed by artist
    /// id. Returns the cached file immediately when present (works offline); else
    /// tries the user's enabled sources and caches the first hit. nil when no
    /// source is on or none has a photo.
    func artistImageURL(forArtist id: String, name: String, sources: [ArtistImageSource]) async -> URL? {
        let dest = artworkDir.appendingPathComponent(Self.stableHash("artist::\(id)") + ".jpg")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard !sources.isEmpty,
              let data = await ArtistImageClient.shared.imageData(forArtist: name, sources: sources),
              !data.isEmpty, OnlineArtworkClient.isImageData(data), Self.isDecodableImage(data) else { return nil }
        try? data.write(to: dest, options: .atomic)
        guard FileManager.default.fileExists(atPath: dest.path) else { return nil }
        applyPlaybackFileProtection(dest)
        return dest
    }

    /// Album artwork for a track fetched straight from the remote source —
    /// folder cover (cover.jpg/folder.jpg/…) first, then embedded art via a
    /// ranged read — so a cover can be obtained WITHOUT the whole track being
    /// downloaded. Falls back to a local/cached file when one exists. This is
    /// what lets streamed tracks show art and lets the library backfill covers
    /// that an older scan never extracted (no full rescan needed).
    func remoteAlbumArtwork(for track: Track) async -> URL? {
        let albumID = track.albumID
        // A prior conclusive "no cover" means don't re-list / re-probe / re-hit the
        // rate-limited online lookup for this album again this session.
        if albumsWithNoRemoteArtwork.contains(albumID) { return nil }
        // Reuse a cover already resolved this session for the album.
        if let url = albumArtworkURLCache[albumID] {
            if FileManager.default.fileExists(atPath: url.path) { return url }
            albumArtworkURLCache[albumID] = nil
        }
        // Coalesce duplicate concurrent requests for the same album (the
        // just-started track triggers both `onTrackStarted` and `loadArtwork`,
        // and the backfill may target the same album) onto one remote fetch.
        if let task = albumArtworkTasks[albumID] { return await task.value.url }
        let task = Task { await self.computeRemoteAlbumArtwork(for: track) }
        albumArtworkTasks[albumID] = task
        let outcome = await task.value
        albumArtworkTasks[albumID] = nil
        if let url = outcome.url {
            albumArtworkURLCache[albumID] = url
        } else if outcome.conclusive {
            albumsWithNoRemoteArtwork.insert(albumID)
        }
        return outcome.url
    }

    static let onlineArtworkKey = "onlineArtwork.enabled.v1"
    static let classicalCreditsKey = "classicalCredits.enabled.v1"

    /// Resolves an album cover and reports whether the (negative) result is
    /// CONCLUSIVE — i.e. an op didn't time out / disconnect along the way. A
    /// transient failure returns `conclusive: false` so the album stays retryable
    /// rather than being marked cover-less for the session.
    private func computeRemoteAlbumArtwork(for track: Track) async -> (url: URL?, conclusive: Bool) {
        loadConfigsFromDiskIfNeeded()
        if let local = await cacheAlbumArtwork(for: track) { return (local, true) }

        var transientFailure = false
        // Remote source: folder cover, then embedded art via a ranged read — a
        // cover WITHOUT downloading the whole track.
        if let cfg = configs.first(where: { $0.id == track.sourceID }),
           cfg.proto != SourceProtocol.local.rawValue,
           let client = backgroundClient(for: cfg),
           let remote = track.remotePath, !remote.isEmpty {
            inFlightBackgroundOps += 1
            defer { inFlightBackgroundOps -= 1 }
            let path = RemotePath(displayPath: remote)
            let ext = (remote as NSString).pathExtension

            let parentComponents = path.remotePathComponents.dropLast()
            if !parentComponents.isEmpty {
                let parent = RemotePath(displayPath: "/" + parentComponents.joined(separator: "/"))
                do {
                    let entries = try await client.list(parent)
                    if let cover = entries.first(where: Self.isFolderCover),
                       let url = await cacheRemoteArtwork(from: cover, client: client) {
                        return (url, true)
                    }
                } catch {
                    transientFailure = true   // couldn't list — not a real "no cover"
                }
            }

            var size = track.sizeBytes
            if size == nil { size = (try? await client.stat(path))?.size }
            if let size, size > 0 {
                let probeLen = min(size, Int64(EmbeddedMetadataReader.defaultProbeLength))
                let entry = RemoteEntry(
                    name: (remote as NSString).lastPathComponent,
                    path: path, kind: .file, size: size, modifiedAt: nil
                )
                do {
                    let probe = try await client.read(path, range: 0..<probeLen)
                    if let art = await remoteArtwork(entry: entry, client: client, probe: probe, ext: ext) {
                        return (cacheEmbeddedArtwork(art, key: "\(cfg.id)::\(track.albumID)"), true)
                    }
                } catch {
                    transientFailure = true   // probe read failed — retry later
                }
            }
        }

        // Last resort (opt-in): online cover lookup by artist + album.
        if UserDefaults.standard.bool(forKey: Self.onlineArtworkKey),
           let data = await OnlineArtworkClient.shared.frontCover(artist: track.artist, album: track.album),
           !data.isEmpty {
            let dest = artworkDir.appendingPathComponent(Self.stableHash("online::\(track.albumID)") + ".jpg")
            if (try? data.write(to: dest, options: .atomic)) != nil,
               FileManager.default.fileExists(atPath: dest.path) {
                applyPlaybackFileProtection(dest)
                return (dest, true)
            }
        }
        return (nil, !transientFailure)
    }

    /// Fetch covers for albums that have no on-disk artwork file yet, from the
    /// remote source. Returns albumID → artwork URL for albums that gained art.
    /// Bounded per call so a large library backfills across a few passes without
    /// hammering the server. Also persists the URLs so they survive relaunch.
    /// Forget which albums were already attempted (and the session URL cache) so a
    /// user-triggered rescan genuinely retries them — otherwise the per-session
    /// "don't re-hit the server for cover-less albums" guard makes a manual
    /// "Fetch missing covers" a no-op after the first automatic pass.
    func resetArtworkAttempts() {
        attemptedArtworkAlbumIDs.removeAll()
        albumArtworkURLCache.removeAll()
        albumsWithNoRemoteArtwork.removeAll()
    }

    func backfillAlbumArtwork(for tracks: [Track], limit: Int = 40) async -> (found: [String: URL], attempted: Int) {
        var hasArt: Set<String> = []
        var representative: [String: Track] = [:]
        for track in tracks where track.kind == .audio {
            if let url = track.artworkURL, url.isFileURL,
               FileManager.default.fileExists(atPath: url.path) {
                hasArt.insert(track.albumID)
            } else if representative[track.albumID] == nil {
                representative[track.albumID] = track
            }
        }
        // Skip albums already attempted this session (covered AND genuinely
        // cover-less) so repeated passes don't re-list/re-read the server for
        // art that isn't there — that converges and stops the AppModel loop.
        // Stable (sorted) order so each pass makes deterministic forward progress.
        let targets = representative
            .filter { !hasArt.contains($0.key) && !attemptedArtworkAlbumIDs.contains($0.key) }
            .sorted { $0.key < $1.key }
            .prefix(limit)
        var result: [String: URL] = [:]
        let attempted = targets.count
        for (albumID, track) in targets {
            if Task.isCancelled { break }
            // Mark attempted ONLY on a conclusive outcome — a found cover, or a
            // confirmed "no cover" (recorded in `albumsWithNoRemoteArtwork` by the
            // lookup). A transient failure (timeout/disconnect) leaves it unmarked
            // so it's retried, instead of permanently skipping a real-cover album.
            if let url = await remoteAlbumArtwork(for: track) {
                attemptedArtworkAlbumIDs.insert(albumID)
                result[albumID] = url
            } else if albumsWithNoRemoteArtwork.contains(albumID) {
                attemptedArtworkAlbumIDs.insert(albumID)
            }
        }
        await applyAlbumArtwork(result)
        return (result, attempted)
    }

    /// Persist a track's real (asset-resolved) duration. A tag-only scan has no
    /// duration, so this fills it in as tracks play and survives relaunch.
    func setDuration(_ seconds: Double, forTrack id: String) async {
        guard seconds.isFinite, seconds > 0,
              let i = allTracks.firstIndex(where: { $0.id == id }),
              abs(allTracks[i].durationSeconds - seconds) > 0.5 else { return }
        allTracks[i].durationSeconds = seconds
        // Column-scoped: a full-row upsert here would rewrite the base text columns
        // from the (maybe user-edited) in-memory track, breaking "revert to file tags".
        try? await mediaStore.setDuration(seconds, identityKey: id)
    }

    /// Persist a favorite toggle so it survives relaunch (a tag-only rescan would
    /// otherwise rebuild from remote and lose it). Upserts by identity.
    func setFavorite(_ isFavorite: Bool, forTrack id: String) async {
        guard let i = allTracks.firstIndex(where: { $0.id == id }),
              allTracks[i].isFavorite != isFavorite else { return }
        allTracks[i].isFavorite = isFavorite
        try? await mediaStore.setFavorite(isFavorite, identityKey: id)
    }

    /// Persist a user metadata edit as a non-destructive override. It survives a
    /// tag rescan (which rewrites the base row from file tags) because the store
    /// overlays overrides at read time. Mutates the in-memory track so the UI
    /// updates immediately, and merges with any existing override so editing one
    /// field later doesn't drop an earlier field's fix. nil = leave that field.
    func setMetadataOverride(forTrack id: String, title: String?, artist: String?, album: String?, genre: String?) async {
        guard let i = allTracks.firstIndex(where: { $0.id == id }) else { return }
        if let title { allTracks[i].title = title }
        if let artist {
            allTracks[i].artist = artist
            allTracks[i].artistID = MetadataGrouping.artistID(artist)
        }
        if let album {
            allTracks[i].album = album
            allTracks[i].albumID = MetadataGrouping.albumID(path: allTracks[i].remotePath ?? allTracks[i].folderPath, album: album)
        }
        if let genre { allTracks[i].genre = genre }

        var merged = (try? await mediaStore.metadataOverride(identityKey: id)) ?? MetadataOverride(identityKey: id)
        if let title { merged.title = title }
        if let artist { merged.artist = artist }
        if let album { merged.album = album }
        if let genre { merged.genre = genre }
        merged.updatedAt = Date()
        if merged.isEmpty {
            try? await mediaStore.deleteMetadataOverride(identityKey: id)
        } else {
            _ = try? await mediaStore.upsertMetadataOverride(merged)
        }
    }

    /// Apply a batch of inferred overrides in a single pass. Builds the id→index
    /// map ONCE (O(N+edits), not O(N×edits) like calling `setMetadataOverride` in a
    /// loop), and each edit merges with any existing override exactly as the
    /// single-track path does. Only the non-nil fields of each fix are written.
    func applyMetadataOverrides(_ fixes: [MetadataAutoFix]) async {
        guard !fixes.isEmpty else { return }
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(allTracks.count)
        for (i, t) in allTracks.enumerated() { indexByID[t.id] = i }

        // Read every existing override ONCE, then write the whole batch in ONE
        // transaction — instead of a read + write round trip per fix.
        let existing = Dictionary(
            ((try? await mediaStore.listMetadataOverrides()) ?? []).map { ($0.identityKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var batch: [MetadataOverride] = []
        for fix in fixes {
            if let i = indexByID[fix.id] {
                if let title = fix.title { allTracks[i].title = title }
                if let artist = fix.artist {
                    allTracks[i].artist = artist
                    allTracks[i].artistID = MetadataGrouping.artistID(artist)
                }
                if let album = fix.album {
                    allTracks[i].album = album
                    allTracks[i].albumID = MetadataGrouping.albumID(path: allTracks[i].remotePath ?? allTracks[i].folderPath, album: album)
                }
            }
            var merged = existing[fix.id] ?? MetadataOverride(identityKey: fix.id)
            if let title = fix.title { merged.title = title }
            if let artist = fix.artist { merged.artist = artist }
            if let album = fix.album { merged.album = album }
            merged.updatedAt = Date()
            if !merged.isEmpty { batch.append(merged) }
        }
        try? await mediaStore.upsertMetadataOverrides(batch)
    }

    /// Remove a track's override and restore the file-scanned values. Returns the
    /// restored fields so the caller can refresh its own in-memory copy (runtime
    /// state like cache/artwork is left untouched), or nil if the row is gone.
    func clearMetadataOverride(forTrack id: String) async -> (title: String, artist: String, album: String, genre: String)? {
        try? await mediaStore.deleteMetadataOverride(identityKey: id)
        guard let i = allTracks.firstIndex(where: { $0.id == id }),
              let item = try? await mediaStore.mediaItem(identityKey: id) else { return nil }
        let fresh = track(fromMediaItem: item)
        allTracks[i].title = fresh.title
        allTracks[i].artist = fresh.artist
        allTracks[i].artistID = fresh.artistID
        allTracks[i].album = fresh.album
        allTracks[i].albumID = fresh.albumID
        allTracks[i].genre = fresh.genre
        return (fresh.title, fresh.artist, fresh.album, fresh.genre)
    }

    /// Apply backfilled covers to the in-memory library and persist the artwork
    /// URLs (upsert by identity, so cache rows and ids are preserved).
    private func applyAlbumArtwork(_ map: [String: URL]) async {
        guard !map.isEmpty else { return }
        var changed: [Track] = []
        for i in allTracks.indices {
            if let url = map[allTracks[i].albumID], allTracks[i].artworkURL != url {
                allTracks[i].artworkURL = url
                changed.append(allTracks[i])
            }
        }
        guard !changed.isEmpty else { return }
        // Column-scoped artwork writes — never rewrite the text columns the overrides
        // overlay on (a full-row upsert here was poisoning "revert to file tags").
        for track in changed {
            try? await mediaStore.setArtworkURL(artworkStorageString(track.artworkURL), identityKey: track.id)
        }
    }

    /// How a cached-artwork URL is persisted: the bare filename, never a
    /// container-absolute path (whose data-container UUID changes on reinstall, which
    /// is what stranded covers before). Remote http URLs are stored whole.
    /// `resolvedArtworkURL` reads both this and any legacy absolute rows.
    private func artworkStorageString(_ url: URL?) -> String? {
        guard let url else { return nil }
        return url.isFileURL ? url.lastPathComponent : url.absoluteString
    }

    private func cacheRemoteArtwork(from entry: RemoteEntry, client: any RemoteFileSystemClient) async -> URL? {
        let ext = ((entry.name as NSString).pathExtension.isEmpty ? "jpg" : (entry.name as NSString).pathExtension).lowercased()
        let dest = artworkDir.appendingPathComponent(Self.stableHash(entry.path.normalizedPath) + "." + ext)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        let maxArtworkBytes: Int64 = 12 * 1_024 * 1_024
        let statSize = (try? await client.stat(entry.path))?.size
        let size = entry.size ?? statSize
        if let size, size > maxArtworkBytes { return nil }

        do {
            let data: Data
            if client.capabilities.supportsByteRangeRead, let size {
                data = try await client.read(entry.path, range: 0..<size)
            } else {
                let tmp = artworkDir.appendingPathComponent(UUID().uuidString + ".art")
                try await client.download(entry.path, to: tmp, progress: nil)
                defer { try? FileManager.default.removeItem(at: tmp) }
                data = (try? Data(contentsOf: tmp)) ?? Data()
            }
            guard !data.isEmpty else { return nil }
            try data.write(to: dest, options: .atomic)
            applyPlaybackFileProtection(dest)
            return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
        } catch {
            return nil
        }
    }

    private func cacheEmbeddedArtwork(_ artwork: EmbeddedArtwork, key: String) -> URL? {
        guard !artwork.data.isEmpty else { return nil }
        let ext = artwork.fileExtension.isEmpty ? "jpg" : artwork.fileExtension
        let dest = artworkDir.appendingPathComponent(Self.stableHash(key) + "." + ext)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        do {
            try artwork.data.write(to: dest, options: .atomic)
            applyPlaybackFileProtection(dest)
            return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
        } catch {
            return nil
        }
    }

    // MARK: Internals

    /// Loads `sources.json`. Returns true when `configs` is authoritative (file
    /// absent = fresh install = legitimately empty, or file read+decoded). A
    /// present-but-unreadable file leaves state `.failed` and returns false WITHOUT
    /// marking loaded, so a later call retries and destructive prune/migration is
    /// skipped in the meantime.
    @discardableResult
    private func loadConfigsFromDiskIfNeeded() -> Bool {
        if case .loaded = configLoadState { return true }
        let fm = FileManager.default
        guard fm.fileExists(atPath: configsURL.path) else {
            configs = []
            configLoadState = .loaded   // genuinely no sources yet
            return true
        }
        do {
            let data = try Data(contentsOf: configsURL)
            configs = try JSONDecoder().decode([SourceConfig].self, from: data)
            configLoadState = .loaded
            return true
        } catch {
            // Present but unreadable/undecodable: do NOT mark loaded, do NOT
            // treat as empty (that would wipe the library).
            configLoadState = .failed
            #if DEBUG
            AppLog.library.error("BETTERSTREAMING_CONFIG load_failed error=\(error, privacy: .public)")
            #endif
            return false
        }
    }

    private func loadLibraryFromDiskIfNeeded() async {
        let configsOK = loadConfigsFromDiskIfNeeded()
        guard !didLoadLibraryFromDisk else { return }
        // If configs couldn't be read this launch, defer library loading rather
        // than risk pruning/migrating against an empty source list.
        guard configsOK else { return }
        // Set the guard BEFORE the await (reentrancy protection: a second caller during
        // the read bails), but release it on a transient read throw so a later call
        // retries instead of stranding an empty library for the session.
        didLoadLibraryFromDisk = true
        guard let items = try? await mediaStore.listMediaItems() else {
            didLoadLibraryFromDisk = false
            return
        }
        if !items.isEmpty {
            let knownSourceIDs = Set(configs.compactMap { UUID(uuidString: $0.id) })
            let filteredItems = items.filter { knownSourceIDs.contains($0.identity.sourceID.rawValue) }
            // Only prune orphans when configs are authoritative (always true here
            // because of the configsOK guard above).
            let orphanedSourceIDs = Set(items.map(\.identity.sourceID)).filter { !knownSourceIDs.contains($0.rawValue) }
            for sourceID in orphanedSourceIDs {
                try? await mediaStore.deleteMediaItems(sourceID: sourceID)
            }
            #if DEBUG
            if filteredItems.count != items.count {
                AppLog.library.debug("BETTERSTREAMING_LIBRARY dropped_orphan_tracks count=\(items.count - filteredItems.count) sources=\(orphanedSourceIDs.count)")
            }
            #endif
            allTracks = filteredItems.map(track(fromMediaItem:))
            refreshCacheStates()
            reconcileCacheFiles()
            return
        }
        if let data = try? Data(contentsOf: legacyLibraryURL),
           let decoded = try? JSONDecoder().decode([Track].self, from: data) {
            let knownSourceIDs = Set(configs.map(\.id))
            allTracks = decoded.filter { knownSourceIDs.contains($0.sourceID) }
            refreshCacheStates()
            reconcileCacheFiles()
            await persistLibrary(tracks: allTracks)
        }
    }

    private func makeClient(_ cfg: SourceConfig) -> (any RemoteFileSystemClient)? {
        let password = sessionPasswords[cfg.id] ?? KeychainStore.get(account: cfg.id)
        guard cfg.proto == SourceProtocol.local.rawValue || password?.isEmpty == false else {
            return nil
        }
        return Self.buildClient(
            proto: cfg.proto, host: cfg.host, port: cfg.port, share: cfg.share,
            username: cfg.username, domain: cfg.domain, password: password
        )
    }

    /// The dedicated playback-stream client for a source (cached + reused). Used
    /// only by `playableItem` so live reads never queue behind a background
    /// download holding the connection's op-lock.
    private func streamClient(for cfg: SourceConfig) -> (any RemoteFileSystemClient)? {
        if let client = streamClients[cfg.id] { return client }
        guard let client = makeClient(cfg) else { return nil }
        streamClients[cfg.id] = client
        return client
    }

    /// The shared background client for a source (cached + reused) — scan,
    /// artwork, and full-file downloads. One connection for all background work,
    /// kept off the streaming connection.
    private func backgroundClient(for cfg: SourceConfig) -> (any RemoteFileSystemClient)? {
        if let client = backgroundClients[cfg.id] { return client }
        guard let client = makeClient(cfg) else { return nil }
        backgroundClients[cfg.id] = client
        return client
    }

    /// Tear down every cached connection for a source (non-blocking). The clients
    /// reconnect lazily on next use.
    private func disconnectClients(for sourceID: String) async {
        if let client = streamClients.removeValue(forKey: sourceID) { await client.disconnect() }
        if let client = backgroundClients.removeValue(forKey: sourceID) { await client.disconnect() }
    }

    /// Drop the background connections when the app is backgrounded so idle
    /// scan/artwork/download sessions are returned to the server. Stream clients
    /// are kept: audio keeps playing in the background. They reconnect lazily.
    func handleEnteredBackground() async {
        // Don't cut a scan's — or an in-flight download/artwork/lyrics read's —
        // connection out from under it.
        guard !scanInProgress, inFlightBackgroundOps == 0 else { return }
        let clients = Array(backgroundClients.values)
        backgroundClients.removeAll()
        for client in clients { await client.disconnect() }
    }

    /// Pure client factory shared by scanning and the transient folder browser.
    nonisolated static func buildClient(
        proto: String, host: String, port: Int, share: String,
        username: String?, domain: String?, password: String?
    ) -> (any RemoteFileSystemClient)? {
        switch proto {
        case SourceProtocol.smb.rawValue:
            let configuration = SMBConnectionConfiguration(
                host: host, port: port, share: share, username: username, domain: domain
            )
            let auth = SMBAuthentication(username: username, domain: domain) { password }
            return SMBRemoteClient(configuration: configuration, authentication: auth)
        case SourceProtocol.webDAV.rawValue:
            #if canImport(WebDAVRemote)
            // 80 = plain http by definition; 5005 = Synology's HTTP-WebDAV default.
            // 8080 deliberately NOT listed — it's a common https reverse-proxy port
            // and forcing http there would break working setups. Real fix (an
            // explicit scheme field on the source) stays queued.
            let scheme = [80, 5005].contains(port) ? "http" : "https"
            guard let base = URL(string: "\(scheme)://\(host):\(port)/\(share)") else { return nil }
            return WebDAVRemoteClient(baseURL: base, username: username, password: password)
            #else
            return nil
            #endif
        case SourceProtocol.ftp.rawValue:
            return FTPRemoteClient(
                host: host,
                port: port == 0 ? SourceProtocol.ftp.defaultPort : port,
                basePath: share,
                username: username,
                password: password
            )
        case SourceProtocol.sftp.rawValue:
            guard let username, let password else { return nil }
            return SFTPRemoteClient(
                host: host,
                port: port == 0 ? SourceProtocol.sftp.defaultPort : port,
                basePath: share,
                username: username,
                password: password
            )
        default:
            return nil
        }
    }

    /// List the directories under `path` using transient credentials (for the
    /// folder picker, before a source is saved).
    func listFolders(
        proto: String, host: String, port: Int, share: String,
        username: String?, domain: String?, password: String?, path: String
    ) async -> Result<[RemoteFolder], LibraryError> {
        guard let client = Self.buildClient(
            proto: proto, host: host, port: port, share: share,
            username: username, domain: domain, password: password
        ) else {
            return .failure(LibraryError(kind: .other, message: "This protocol can’t be browsed yet."))
        }
        // Transient, per-browse client — tear its session down on the way out so
        // repeated folder browsing during setup doesn't leak server sessions.
        defer { Task { await client.disconnect() } }
        do {
            let entries = try await client.list(RemotePath(displayPath: path.isEmpty ? "/" : path))
            let folders = entries
                .filter { $0.kind == .directory }
                .map { RemoteFolder(name: $0.name, path: $0.path.displayPath) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return .success(folders)
        } catch {
            return .failure(Self.libraryError(from: error))
        }
    }

    // MARK: Local files

    private func localRootURL(for cfg: SourceConfig) -> URL? {
        if let url = localRoots[cfg.id] { return url }
        guard let b64 = cfg.bookmark, let data = Data(base64Encoded: b64) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        localRoots[cfg.id] = url
        return url
    }

    private func scanLocal(_ cfg: SourceConfig) async throws -> [Track] {
        guard let root = localRootURL(for: cfg) else {
            throw LibraryError(kind: .notFound, message: "Couldn’t open the chosen folder. Pick it again.")
        }
        var scanned = Self.localTracks(root: root, cfg: cfg)
        await attachLocalArtwork(&scanned)
        return scanned
    }

    nonisolated private static func localTracks(root: URL, cfg: SourceConfig) -> [Track] {
        let classifier = MediaFileClassifier()
        var scanned: [Track] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in enumerator {
                if scanned.count >= 100_000 { break }
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true,
                      let kind = classifier.classify(fileName: url.lastPathComponent) else { continue }
                let embedded = embeddedMetadataFromLocalFile(url)
                scanned.append(localTrack(
                    url: url,
                    root: root,
                    kind: kind,
                    cfg: cfg,
                    size: values?.fileSize,
                    modified: values?.contentModificationDate,
                    embedded: embedded
                ))
            }
        }
        return scanned
    }

    /// Per album: use a folder cover image (cover.jpg/folder.jpg/…) if present,
    /// otherwise extract embedded artwork from a track — so covers show in the
    /// library without playing.
    private func attachLocalArtwork(_ tracks: inout [Track]) async {
        var coverByAlbum: [String: URL] = [:]
        var dirChecked: [String: URL?] = [:]
        for i in tracks.indices {
            let albumID = tracks[i].albumID
            if let url = coverByAlbum[albumID] { tracks[i].artworkURL = url; continue }
            let dir = URL(fileURLWithPath: tracks[i].remotePath ?? tracks[i].folderPath).deletingLastPathComponent()
            let folderCover: URL?
            if let cached = dirChecked[dir.path] {
                folderCover = cached
            } else {
                folderCover = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                    .first { Self.folderCoverNames.contains($0.lastPathComponent.lowercased()) }
                dirChecked[dir.path] = folderCover
            }
            let art: URL?
            if let folderCover {
                art = folderCover
            } else {
                art = await cacheAlbumArtwork(for: tracks[i])
            }
            if let art {
                coverByAlbum[albumID] = art
                tracks[i].artworkURL = art
            }
        }
    }

    nonisolated private static func localTrack(
        url: URL,
        root: URL,
        kind: IndexedMediaKind,
        cfg: SourceConfig,
        size: Int?,
        modified: Date?,
        embedded: EmbeddedMediaMetadata? = nil
    ) -> Track {
        let path = url.path
        let metadata = Self.resolvedTrackMetadata(
            fileName: url.lastPathComponent,
            pathComponents: url.pathComponents,
            rootComponents: root.pathComponents,
            sourceName: cfg.name,
            embedded: embedded
        )
        return Track(
            id: "local-" + Self.stableHash(path),
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            // albumID/artistID derived from folder + feat-stripped artist by the
            // Track initializer (see MetadataGrouping) — do not key on raw artist.
            genre: metadata.genre,
            durationSeconds: metadata.durationSeconds,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            kind: kind == .audio ? .audio : .video,
            cacheState: .cached,
            sourceID: cfg.id,
            sourceName: cfg.name,
            folderPath: path,
            shareID: cfg.shareID,
            remotePath: path,
            sizeBytes: size.map(Int64.init),
            modifiedAtEpoch: modified?.timeIntervalSince1970
        )
    }

    nonisolated private static func embeddedMetadataFromLocalFile(_ url: URL) -> EmbeddedMediaMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: EmbeddedMetadataReader.defaultProbeLength),
              !data.isEmpty else {
            return nil
        }
        let metadata = EmbeddedMetadataReader.parse(data, fileExtension: url.pathExtension)
        if !metadata.isEmpty { return metadata }
        // MP4/M4A with moov at end of file: the head read missed the tags. Derive
        // the trailing-moov range and read just that region.
        let fileLength = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        guard let fileLength, fileLength > 0,
              let tailRange = EmbeddedMetadataReader.mp4MetadataTailRange(head: [UInt8](data), fileLength: fileLength),
              tailRange.upperBound - tailRange.lowerBound <= 8 * 1_024 * 1_024,
              (try? handle.seek(toOffset: UInt64(tailRange.lowerBound))) != nil,
              let tail = try? handle.read(upToCount: Int(tailRange.upperBound - tailRange.lowerBound)),
              !tail.isEmpty else { return nil }
        let merged = EmbeddedMetadataReader.parse(head: data, tail: tail, fileExtension: url.pathExtension)
        return merged.isEmpty ? nil : merged
    }

    /// Resolved on-disk URL for a local-source track (security scope active), else nil.
    private func localFileURL(for track: Track) -> URL? {
        guard let cfg = configs.first(where: { $0.id == track.sourceID }),
              cfg.proto == SourceProtocol.local.rawValue,
              localRootURL(for: cfg) != nil else { return nil }
        let url = URL(fileURLWithPath: track.remotePath ?? track.folderPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func remoteIdentity(for track: Track, cfg: SourceConfig) -> RemoteItemIdentity {
        RemoteItemIdentity(
            sourceID: SourceID(rawValue: UUID(uuidString: cfg.id) ?? UUID()),
            shareID: ShareID(rawValue: UUID(uuidString: track.shareID ?? cfg.shareID) ?? UUID()),
            path: RemotePath(displayPath: track.remotePath ?? track.folderPath),
            remoteFileID: nil,
            size: track.sizeBytes,
            modifiedAt: track.modifiedAtEpoch.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func cacheFileURL(for track: Track) -> URL {
        Self.cacheFileURL(for: track, cacheDir: cacheDir)
    }

    private func cachedFileURLIfPresent(for track: Track) -> URL? {
        let local = cacheFileURL(for: track)
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// Track ids whose partial-stream scratch file is currently in use by a live
    /// session, so a second concurrent session for the same track doesn't get the
    /// same deterministic path (which its teardown could delete under the first).
    private var liveStreamTrackIDs: Set<String> = []

    /// Partial-stream scratch path. Deterministic per track
    /// (`stream-<hash>.<ext>`) so the `.ranges` sidecar written by the streaming
    /// service is found again on a later session — a 90%-streamed track resumes
    /// instead of refetching from byte 0. BUT if a session for this track is already
    /// live, fall back to a UUID-suffixed name so two live sessions never share one
    /// file (whose older teardown would delete the newer session's bytes).
    private func streamCacheFileURL(for track: Track) -> URL {
        let ext = track.fileExtension.isEmpty ? "dat" : track.fileExtension
        let base = "stream-\(Self.stableHash(track.id))"
        if liveStreamTrackIDs.contains(track.id) {
            return streamCacheDir.appendingPathComponent("\(base)-\(UUID().uuidString).\(ext)")
        }
        liveStreamTrackIDs.insert(track.id)
        return streamCacheDir.appendingPathComponent("\(base).\(ext)")
    }

    /// One directory listing of the download cache, mapped `<hash> → byte size`.
    /// Replaces the per-track `fileExists` fan-out (a 10k-file library did 10k
    /// stat syscalls) — both `refreshCacheStates` (existence via keys) and
    /// `autoCachedBytes` (sum via values) read this single listing. The basename
    /// hash is the part before the first ".", exactly as `reconcileCacheFiles`
    /// derives it; in-flight download temps are excluded so a `.part` isn't counted.
    private func cacheFileSizesByHash() -> [String: Int] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [:] }
        let tempSuffixes = [".part", ".download", ".promote"]
        var result: [String: Int] = [:]
        result.reserveCapacity(entries.count)
        for url in entries where !tempSuffixes.contains(where: url.lastPathComponent.hasSuffix) {
            let name = url.lastPathComponent
            let base = name.firstIndex(of: ".").map { String(name[..<$0]) } ?? name
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            result[base] = size
        }
        return result
    }

    private func refreshCacheStates() {
        loadAutoCacheIndexIfNeeded()
        let localIDs = Set(configs.filter { $0.proto == SourceProtocol.local.rawValue }.map(\.id))
        let cachedHashes = Set(cacheFileSizesByHash().keys)
        var prunedIndex = false
        for index in allTracks.indices {
            if localIDs.contains(allTracks[index].sourceID) {
                allTracks[index].cacheState = .cached   // local files are always on-device
                continue
            }
            let id = allTracks[index].id
            let isCached = cachedHashes.contains(Self.stableHash(id))
            if isCached {
                // Auto-cached/streamed files are evictable (.prefetched); manual
                // downloads are pinned (.cached).
                let desired: CacheState = autoCachedIDs.contains(id) ? .prefetched : .cached
                if allTracks[index].cacheState != desired { allTracks[index].cacheState = desired }
            } else {
                if allTracks[index].cacheState == .cached || allTracks[index].cacheState == .prefetched {
                    allTracks[index].cacheState = .remoteOnly
                }
                // File gone but still flagged auto-cached → drop the stale flag.
                if autoCachedIDs.contains(id) { autoCachedIDs.remove(id); prunedIndex = true }
            }
        }
        if prunedIndex { persistAutoCacheIndex() }
    }

    private static func cacheFileURL(for track: Track, cacheDir: URL) -> URL {
        let ext = (track.remotePath ?? track.folderPath as String) as NSString
        let pathExtension = ext.pathExtension.isEmpty ? "dat" : ext.pathExtension
        return cacheDir.appendingPathComponent("\(stableHash(track.id)).\(pathExtension)")
    }

    private func persistConfigs() {
        if let data = try? JSONEncoder().encode(configs) { try? data.write(to: configsURL, options: .atomic) }
    }

    private func persistLibrary(sourceID: String, tracks: [Track]) async {
        guard let uuid = UUID(uuidString: sourceID) else {
            await persistLibrary(tracks: allTracks)
            return
        }
        do {
            try await mediaStore.replaceMediaItems(tracks.map(mediaItem(from:)), for: SourceID(rawValue: uuid))
            try? FileManager.default.removeItem(at: legacyLibraryURL)
        } catch {
            // The old `library.json` fallback was write-only (only ever READ when the
            // store is empty, which it isn't after a failed write), so it created a
            // false sense of durability. Log loudly instead; the in-memory library
            // still holds this scan until the next successful persist.
            streamLog.error("persist sqlite_write_failed source=\(sourceID, privacy: .public) err=\(String(describing: error), privacy: .public)")
        }
    }

    private func persistLibrary(tracks: [Track]) async {
        do {
            try await mediaStore.replaceAllMediaItems(tracks.map(mediaItem(from:)))
            try? FileManager.default.removeItem(at: legacyLibraryURL)
        } catch {
            streamLog.error("persist sqlite_write_failed_all err=\(String(describing: error), privacy: .public)")
        }
    }

    private func mediaItem(from track: Track) -> MediaItem {
        let cfg = configs.first { $0.id == track.sourceID }
        let identity = remoteIdentity(for: track, cfg: cfg ?? SourceConfig(
            id: track.sourceID,
            shareID: track.shareID ?? UUID().uuidString,
            name: track.sourceName,
            proto: SourceProtocol.smb.rawValue,
            host: "",
            port: 0,
            share: "",
            username: nil,
            domain: nil,
            rootPath: "/"
        ))
        return MediaItem(
            identity: identity,
            mediaKind: track.kind == .audio ? EvensongDomain.MediaKind.audio : EvensongDomain.MediaKind.video,
            fileName: ((track.remotePath ?? track.folderPath) as NSString).lastPathComponent,
            title: track.title,
            artist: track.artist,
            album: track.album,
            genre: track.genre,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            duration: track.durationSeconds > 0 ? track.durationSeconds : nil,
            artworkURL: track.artworkURL,
            isFavorite: track.isFavorite,
            playbackCapability: .playable
        )
    }

    private func track(fromMediaItem item: MediaItem) -> Track {
        let cfg = configs.first { UUID(uuidString: $0.id) == item.identity.sourceID.rawValue }
        let sourceID = cfg?.id ?? item.identity.sourceID.rawValue.uuidString
        let sourceName = cfg?.name ?? "Source"
        let path = item.identity.path.displayPath
        let parsed = Self.parseTrack((item.fileName as NSString).deletingPathExtension)
        let title = Self.cleanMetadataValue(item.title) ?? parsed.title
        let artist = Self.cleanMetadataValue(item.artist) ?? "Unknown Artist"
        let album = Self.cleanMetadataValue(item.album) ?? sourceName
        return Track(
            id: item.identity.stableKey,
            title: title,
            artist: artist,
            album: album,
            genre: Self.cleanMetadataValue(item.genre) ?? "Unknown",
            durationSeconds: item.duration ?? 0,
            trackNumber: item.trackNumber ?? parsed.number,
            discNumber: item.discNumber,
            kind: item.mediaKind == EvensongDomain.MediaKind.video ? .video : .audio,
            cacheState: .remoteOnly,
            isFavorite: item.isFavorite,
            sourceID: sourceID,
            sourceName: sourceName,
            folderPath: path,
            artworkURL: resolvedArtworkURL(item.artworkURL),
            shareID: item.identity.shareID.rawValue.uuidString,
            remotePath: path,
            sizeBytes: item.identity.size,
            modifiedAtEpoch: item.identity.modifiedAt?.timeIntervalSince1970
        )
    }

    /// Resolve a persisted artwork reference to a usable URL. Cached art is stored as a
    /// bare filename (see `artworkStorageString`); older rows may hold an absolute file
    /// URL whose data-container UUID has since changed on a delete+reinstall. Either way,
    /// resolve by filename against the CURRENT artwork dir; drop it if the file is
    /// genuinely gone so the backfill re-fetches. Remote http(s) URLs pass through.
    private func resolvedArtworkURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }
        let candidate = artworkDir.appendingPathComponent(url.lastPathComponent)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private func applyPlaybackFileProtection(_ url: URL) {
        #if os(iOS)
        try? (url as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        #endif
    }

    /// Parse a leading track number off a filename and return the cleaned title.
    /// "05 Avantasia - Song" -> (5, "Avantasia - Song"). Years like "1979 x"
    /// (4+ digits) are left untouched.
    /// Split a "Artist - Title" file-name stem (after the track number has been
    /// removed) into its parts. Uses " - " (space-dash-space) so hyphenated names
    /// ("AC-DC", "Jay-Z") aren't split. Returns nils when there's no separator or
    /// either side is empty / purely numeric, so well-formed "NN - Title" names
    /// (no embedded artist) fall through to folder-derived artist.
    nonisolated static func splitArtistTitle(_ stem: String) -> (artist: String?, title: String?) {
        guard let range = stem.range(of: " - ") else { return (nil, nil) }
        let artist = String(stem[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let title = String(stem[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty, !title.isEmpty else { return (nil, nil) }
        if artist.allSatisfy({ $0.isNumber }) { return (nil, title) }
        return (artist, title)
    }

    nonisolated static func parseTrack(_ rawTitle: String) -> (number: Int?, title: String) {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return (nil, trimmed) }
        var rest = trimmed.dropFirst(digits.count)
        rest = rest.drop(while: { " .-_)\t".contains($0) })
        let title = rest.trimmingCharacters(in: .whitespaces)
        return (number, title.isEmpty ? trimmed : title)
    }

    /// True when the bytes decode as an image (guards against a valid-magic but
    /// truncated/corrupt payload the magic-byte check alone would accept).
    nonisolated private static func isDecodableImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceGetType(source) != nil
    }

    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
