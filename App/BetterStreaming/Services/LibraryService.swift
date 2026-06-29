import AVFoundation
import BetterStreamingDomain
import Foundation
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
    private let mediaStore: MediaStore
    private let streamingService = RemoteStreamingService()

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
    /// In-memory passwords for this session, set on add. Lets the first
    /// add→scan succeed even if the Keychain read lags/fails; Keychain remains
    /// the durable store for relaunches.
    private var sessionPasswords: [String: String] = [:]
    /// Resolved + security-scope-accessing folder URLs for local sources, by id.
    private var localRoots: [String: URL] = [:]

    init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        cacheDir = caches.appendingPathComponent("Media", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        artworkDir = caches.appendingPathComponent("Artwork", isDirectory: true)
        try? fm.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        streamCacheDir = caches.appendingPathComponent("StreamingRanges", isDirectory: true)
        try? fm.createDirectory(at: streamCacheDir, withIntermediateDirectories: true)
        configsURL = support.appendingPathComponent("sources.json")
        legacyLibraryURL = support.appendingPathComponent("library.json")
        autoCacheIndexURL = support.appendingPathComponent("autocache.json")
        mediaStore = MediaStore(configuration: MediaStoreConfiguration(databaseURL: support.appendingPathComponent("library.sqlite")))
        // Partial streaming scratch is per-session and not reused across
        // launches; reclaim any partials orphaned by a previous run.
        if let stale = try? fm.contentsOfDirectory(at: streamCacheDir, includingPropertiesForKeys: nil) {
            for url in stale { try? fm.removeItem(at: url) }
        }
    }

    // MARK: Load

    func bootstrap() -> (configs: [SourceConfig], tracks: [Track]) {
        loadConfigsFromDiskIfNeeded()
        return (configs, [])
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
        KeychainStore.set(password, account: id)
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
        if let url = localRoots[id] {
            url.stopAccessingSecurityScopedResource()
            localRoots[id] = nil
        }
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

    /// Recursively scan a source into tracks (path-first). Returns the full
    /// merged library so the caller can replace its state.
    func scan(sourceID: String) async throws -> [Track] {
        await loadLibraryFromDiskIfNeeded()
        guard let cfg = configs.first(where: { $0.id == sourceID }) else { return allTracks }

        if cfg.proto == SourceProtocol.local.rawValue {
            let scanned = try await scanLocal(cfg)
            allTracks.removeAll { $0.sourceID == cfg.id }
            allTracks.append(contentsOf: scanned)
            refreshCacheStates()
            await persistLibrary(sourceID: cfg.id, tracks: scanned)
            return allTracks
        }

        guard let client = makeClient(cfg) else {
            throw LibraryError(kind: .other, message: "This source is missing connection details.")
        }

        // Tolerant recursive walk. The Core RemoteLibraryScanner aborts the whole
        // scan if any single folder fails to list (perms/system dirs), which made
        // real shares show as Unavailable. Here a deep folder failure is skipped;
        // only a failure on the FIRST (root) list is treated as a real connection
        // error and surfaced.
        let classifier = MediaFileClassifier()
        var scanned: [Track] = []
        var pending: [RemotePath] = [RemotePath(displayPath: cfg.rootPath)]
        var visited = Set<String>()
        var listedAnyFolder = false

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
                continue
            }

            let coverEntry = entries.first(where: Self.isFolderCover)
            var directoryTracks: [Track] = []
            var embeddedArtworkByAlbum: [String: URL] = [:]
            for entry in entries {
                switch entry.kind {
                case .directory:
                    if visited.count + pending.count < 50_000 { pending.append(entry.path) }
                case .file:
                    if let kind = classifier.classify(entry), scanned.count < 100_000 {
                        let ext = (entry.name as NSString).pathExtension
                        let probe = await embeddedProbe(for: entry, client: client)
                        let embedded = probe.flatMap { data -> EmbeddedMediaMetadata? in
                            let parsed = EmbeddedMetadataReader.parse(data, fileExtension: ext)
                            return parsed.isEmpty ? nil : parsed
                        }
                        var track = track(fromEntry: entry, kind: kind, cfg: cfg, embedded: embedded)
                        if coverEntry == nil {
                            if let artworkURL = embeddedArtworkByAlbum[track.albumID] {
                                track.artworkURL = artworkURL
                            } else if let artwork = await remoteArtwork(entry: entry, client: client, probe: probe, ext: ext),
                                      let artworkURL = cacheEmbeddedArtwork(artwork, key: "\(cfg.id)::\(track.albumID)") {
                                embeddedArtworkByAlbum[track.albumID] = artworkURL
                                track.artworkURL = artworkURL
                            }
                        }
                        directoryTracks.append(track)
                    }
                default:
                    break
                }
            }
            if let coverEntry,
               !directoryTracks.isEmpty,
               let artworkURL = await cacheRemoteArtwork(from: coverEntry, client: client) {
                for index in directoryTracks.indices {
                    directoryTracks[index].artworkURL = artworkURL
                }
            } else if !embeddedArtworkByAlbum.isEmpty {
                for index in directoryTracks.indices {
                    if let artworkURL = embeddedArtworkByAlbum[directoryTracks[index].albumID] {
                        directoryTracks[index].artworkURL = artworkURL
                    }
                }
            }
            scanned.append(contentsOf: directoryTracks)
        }

        allTracks.removeAll { $0.sourceID == sourceID }
        allTracks.append(contentsOf: scanned)
        refreshCacheStates()
        await persistLibrary(sourceID: sourceID, tracks: scanned)
        return allTracks
    }

    private func track(
        fromEntry entry: RemoteEntry,
        kind: IndexedMediaKind,
        cfg: SourceConfig,
        embedded: EmbeddedMediaMetadata? = nil
    ) -> Track {
        let identity = RemoteItemIdentity(
            sourceID: SourceID(rawValue: UUID(uuidString: cfg.id) ?? UUID()),
            shareID: ShareID(rawValue: UUID(uuidString: cfg.shareID) ?? UUID()),
            path: entry.path,
            remoteFileID: entry.fileID,
            size: entry.size,
            modifiedAt: entry.modifiedAt
        )
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
            albumID: "\(metadata.artist)::\(metadata.album)".lowercased(),
            artistID: metadata.artist.lowercased(),
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

    private struct ResolvedTrackMetadata {
        var title: String
        var artist: String
        var album: String
        var genre: String
        var durationSeconds: Double
        var trackNumber: Int?
        var discNumber: Int?
    }

    nonisolated private static func resolvedTrackMetadata(
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

        let embeddedTitle = cleanMetadataValue(embedded?.title).map(parseTrack)
        let title = embeddedTitle?.title ?? (parsed.title.isEmpty ? fileName : parsed.title)
        let artist = cleanMetadataValue(embedded?.artist) ?? fallbackArtist
        let album = cleanMetadataValue(embedded?.album) ?? fallbackAlbum
        let genre = cleanMetadataValue(embedded?.genre) ?? "Unknown"
        let duration = embedded?.durationSeconds ?? 0

        return ResolvedTrackMetadata(
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            durationSeconds: duration,
            trackNumber: embedded?.trackNumber ?? embeddedTitle?.number ?? parsed.number,
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
            print("BETTERSTREAMING_RESOLVE local_or_cached title=\(track.title) url=\(localURL.path)")
            #endif
            return AVPlayerItem(url: localURL)
        }
        if offline { return nil }
        guard let cfg = configs.first(where: { $0.id == track.sourceID }),
              let client = makeClient(cfg) else {
            #if DEBUG
            let hasConfig = configs.contains(where: { $0.id == track.sourceID })
            print("BETTERSTREAMING_RESOLVE no_client title=\(track.title) source=\(track.sourceID) hasConfig=\(hasConfig)")
            #endif
            return nil
        }

        let identity = remoteIdentity(for: track, cfg: cfg)
        guard client.capabilities.supportsByteRangeRead else {
            #if DEBUG
            print("BETTERSTREAMING_RESOLVE full_download_fallback no_range title=\(track.title)")
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
                print("BETTERSTREAMING_RESOLVE full_download_fallback stat title=\(track.title) kind=\(metadata.kind) size=\(metadata.size ?? -1) range=\(metadata.supportsRangeRead)")
                #endif
                guard let url = await playableURL(for: track, offline: false) else { return nil }
                return AVPlayerItem(url: url)
            }
            #if DEBUG
            print("BETTERSTREAMING_RESOLVE streaming title=\(track.title) ext=\(track.fileExtension) size=\(size) path=\(identity.path.displayPath)")
            #endif
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
                onComplete: { [weak self] in await self?.onStreamFullyCached(trackID) }
            )
        } catch {
            #if DEBUG
            print("BETTERSTREAMING_RESOLVE stat_error title=\(track.title) error=\(error)")
            #endif
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
              let client = makeClient(cfg) else { return nil }

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

    /// Called by the streaming service once a track has been fully streamed and
    /// copied into the media cache. Treated as an (evictable) auto-cache entry.
    func onStreamFullyCached(_ id: String) {
        markAutoCached(id)
        applyPlaybackFileProtectionForCached(id)
        refreshCacheStates()
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
        var total: Int64 = 0
        for track in allTracks where autoCachedIDs.contains(track.id) {
            let url = Self.cacheFileURL(for: track, cacheDir: cacheDir)
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
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

    /// Extract embedded artwork from a locally-available track and cache a
    /// shared thumbnail per album. Returns the cached file URL (or nil).
    func cacheAlbumArtwork(for track: Track) async -> URL? {
        let dest = artworkDir.appendingPathComponent(Self.stableHash(track.albumID) + ".jpg")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let data = await artworkData(for: track) else { return nil }
        try? data.write(to: dest, options: .atomic)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
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
            print("BETTERSTREAMING_CONFIG load_failed error=\(error)")
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
        didLoadLibraryFromDisk = true
        if let items = try? await mediaStore.listMediaItems(), !items.isEmpty {
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
                print("BETTERSTREAMING_LIBRARY dropped_orphan_tracks count=\(items.count - filteredItems.count) sources=\(orphanedSourceIDs.count)")
            }
            #endif
            allTracks = filteredItems.map(track(fromMediaItem:))
            refreshCacheStates()
            return
        }
        if let data = try? Data(contentsOf: legacyLibraryURL),
           let decoded = try? JSONDecoder().decode([Track].self, from: data) {
            let knownSourceIDs = Set(configs.map(\.id))
            allTracks = decoded.filter { knownSourceIDs.contains($0.sourceID) }
            refreshCacheStates()
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
            let scheme = port == 80 ? "http" : "https"
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
            albumID: "\(metadata.artist)::\(metadata.album)".lowercased(),
            artistID: metadata.artist.lowercased(),
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
        return metadata.isEmpty ? nil : metadata
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

    private func streamCacheFileURL(for track: Track) -> URL {
        let ext = track.fileExtension.isEmpty ? "dat" : track.fileExtension
        return streamCacheDir.appendingPathComponent("\(Self.stableHash(track.id)).\(ext)")
    }

    private func refreshCacheStates() {
        loadAutoCacheIndexIfNeeded()
        let localIDs = Set(configs.filter { $0.proto == SourceProtocol.local.rawValue }.map(\.id))
        var prunedIndex = false
        for index in allTracks.indices {
            if localIDs.contains(allTracks[index].sourceID) {
                allTracks[index].cacheState = .cached   // local files are always on-device
                continue
            }
            let id = allTracks[index].id
            let isCached = FileManager.default.fileExists(atPath: Self.cacheFileURL(for: allTracks[index], cacheDir: cacheDir).path)
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
            await persistLegacyLibrary()
        }
    }

    private func persistLibrary(tracks: [Track]) async {
        do {
            try await mediaStore.replaceAllMediaItems(tracks.map(mediaItem(from:)))
            try? FileManager.default.removeItem(at: legacyLibraryURL)
        } catch {
            await persistLegacyLibrary()
        }
    }

    private func persistLegacyLibrary() async {
        if let data = try? JSONEncoder().encode(allTracks) {
            try? data.write(to: legacyLibraryURL, options: .atomic)
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
            mediaKind: track.kind == .audio ? BetterStreamingDomain.MediaKind.audio : BetterStreamingDomain.MediaKind.video,
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
            kind: item.mediaKind == BetterStreamingDomain.MediaKind.video ? .video : .audio,
            cacheState: .remoteOnly,
            isFavorite: item.isFavorite,
            sourceID: sourceID,
            sourceName: sourceName,
            folderPath: path,
            artworkURL: item.artworkURL,
            shareID: item.identity.shareID.rawValue.uuidString,
            remotePath: path,
            sizeBytes: item.identity.size,
            modifiedAtEpoch: item.identity.modifiedAt?.timeIntervalSince1970
        )
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
    static func parseTrack(_ rawTitle: String) -> (number: Int?, title: String) {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return (nil, trimmed) }
        var rest = trimmed.dropFirst(digits.count)
        rest = rest.drop(while: { " .-_)\t".contains($0) })
        let title = rest.trimmingCharacters(in: .whitespaces)
        return (number, title.isEmpty ? trimmed : title)
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
