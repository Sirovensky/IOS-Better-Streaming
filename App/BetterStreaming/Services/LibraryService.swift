import AVFoundation
import BetterStreamingDomain
import Foundation
import LibraryIndexer
import RemoteFileSystem
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
    private let configsURL: URL
    private let libraryURL: URL

    private var configs: [SourceConfig] = []
    private var allTracks: [Track] = []
    private var didLoadConfigsFromDisk = false
    private var didLoadLibraryFromDisk = false
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
        configsURL = support.appendingPathComponent("sources.json")
        libraryURL = support.appendingPathComponent("library.json")
    }

    // MARK: Load

    func bootstrap() -> (configs: [SourceConfig], tracks: [Track]) {
        loadConfigsFromDiskIfNeeded()
        return (configs, [])
    }

    func loadSavedLibrary() -> [Track] {
        loadLibraryFromDiskIfNeeded()
        return allTracks
    }

    func refreshCacheSnapshot() -> [Track] {
        loadLibraryFromDiskIfNeeded()
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

    func removeSource(_ id: String) {
        loadLibraryFromDiskIfNeeded()
        if let url = localRoots[id] {
            url.stopAccessingSecurityScopedResource()
            localRoots[id] = nil
        }
        configs.removeAll { $0.id == id }
        allTracks.removeAll { $0.sourceID == id }
        KeychainStore.delete(account: id)
        persistConfigs()
        persistLibrary()
    }

    func configList() -> [SourceConfig] {
        loadConfigsFromDiskIfNeeded()
        return configs
    }

    // MARK: Scan

    /// Recursively scan a source into tracks (path-first). Returns the full
    /// merged library so the caller can replace its state.
    func scan(sourceID: String) async throws -> [Track] {
        loadLibraryFromDiskIfNeeded()
        guard let cfg = configs.first(where: { $0.id == sourceID }) else { return allTracks }

        if cfg.proto == SourceProtocol.local.rawValue {
            let scanned = try await scanLocal(cfg)
            allTracks.removeAll { $0.sourceID == cfg.id }
            allTracks.append(contentsOf: scanned)
            refreshCacheStates()
            persistLibrary()
            return allTracks
        }

        guard let client = makeClient(cfg) else { return allTracks }

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

            for entry in entries {
                switch entry.kind {
                case .directory:
                    if visited.count + pending.count < 50_000 { pending.append(entry.path) }
                case .file:
                    if let kind = classifier.classify(entry), scanned.count < 100_000 {
                        scanned.append(track(fromEntry: entry, kind: kind, cfg: cfg))
                    }
                default:
                    break
                }
            }
        }

        allTracks.removeAll { $0.sourceID == sourceID }
        allTracks.append(contentsOf: scanned)
        refreshCacheStates()
        persistLibrary()
        return allTracks
    }

    private func track(fromEntry entry: RemoteEntry, kind: IndexedMediaKind, cfg: SourceConfig) -> Track {
        let identity = RemoteItemIdentity(
            sourceID: SourceID(rawValue: UUID(uuidString: cfg.id) ?? UUID()),
            shareID: ShareID(rawValue: UUID(uuidString: cfg.shareID) ?? UUID()),
            path: entry.path,
            remoteFileID: entry.fileID,
            size: entry.size,
            modifiedAt: entry.modifiedAt
        )
        let components = entry.path.remotePathComponents
        let parsed = Self.parseTrack((entry.name as NSString).deletingPathExtension)
        let album = components.count >= 2 ? components[components.count - 2] : cfg.name
        let artist = components.count >= 3 ? components[components.count - 3] : "Unknown Artist"
        return Track(
            id: identity.stableKey,
            title: parsed.title.isEmpty ? entry.name : parsed.title,
            artist: artist,
            album: album,
            albumID: "\(artist)::\(album)".lowercased(),
            artistID: artist.lowercased(),
            genre: "Unknown",
            durationSeconds: 0,
            trackNumber: parsed.number,
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

    func playableURL(for track: Track, offline: Bool) async -> URL? {
        loadConfigsFromDiskIfNeeded()
        if let localURL = localFileURL(for: track) { return localURL }   // local source: play in place
        let local = cacheFileURL(for: track)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        if offline { return nil }
        guard let cfg = configs.first(where: { $0.id == track.sourceID }),
              let client = makeClient(cfg) else { return nil }

        let identity = remoteIdentity(for: track, cfg: cfg)
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

    /// Force-download (manual pin / auto-cache keep). Returns true if cached.
    @discardableResult
    func ensureCached(_ track: Track) async -> Bool {
        if isCached(track) { return true }
        return await playableURL(for: track, offline: false) != nil
    }

    func evict(_ track: Track) {
        try? FileManager.default.removeItem(at: cacheFileURL(for: track))
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

    // MARK: Internals

    private func loadConfigsFromDiskIfNeeded() {
        guard !didLoadConfigsFromDisk else { return }
        didLoadConfigsFromDisk = true
        if let data = try? Data(contentsOf: configsURL),
           let decoded = try? JSONDecoder().decode([SourceConfig].self, from: data) {
            configs = decoded
        }
    }

    private func loadLibraryFromDiskIfNeeded() {
        loadConfigsFromDiskIfNeeded()
        guard !didLoadLibraryFromDisk else { return }
        didLoadLibraryFromDisk = true
        if let data = try? Data(contentsOf: libraryURL),
           let decoded = try? JSONDecoder().decode([Track].self, from: data) {
            allTracks = decoded
        }
    }

    private func makeClient(_ cfg: SourceConfig) -> (any RemoteFileSystemClient)? {
        let password = sessionPasswords[cfg.id] ?? KeychainStore.get(account: cfg.id)
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
        default:
            // FTP / SFTP adapters not built yet.
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
        let classifier = MediaFileClassifier()
        var scanned: [Track] = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in enumerator {
                if scanned.count >= 100_000 { break }
                let values = try? url.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true,
                      let kind = classifier.classify(fileName: url.lastPathComponent) else { continue }
                scanned.append(localTrack(url: url, kind: kind, cfg: cfg, size: values?.fileSize, modified: values?.contentModificationDate))
            }
        }
        await attachLocalArtwork(&scanned)
        return scanned
    }

    /// Per album: use a folder cover image (cover.jpg/folder.jpg/…) if present,
    /// otherwise extract embedded artwork from a track — so covers show in the
    /// library without playing.
    private func attachLocalArtwork(_ tracks: inout [Track]) async {
        var coverByAlbum: [String: URL] = [:]
        var dirChecked: [String: URL?] = [:]
        let names: Set<String> = ["cover.jpg", "folder.jpg", "front.jpg", "cover.png", "folder.png", "album.jpg", "albumart.jpg"]
        for i in tracks.indices {
            let albumID = tracks[i].albumID
            if let url = coverByAlbum[albumID] { tracks[i].artworkURL = url; continue }
            let dir = URL(fileURLWithPath: tracks[i].remotePath ?? tracks[i].folderPath).deletingLastPathComponent()
            let folderCover: URL?
            if let cached = dirChecked[dir.path] {
                folderCover = cached
            } else {
                folderCover = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                    .first { names.contains($0.lastPathComponent.lowercased()) }
                dirChecked[dir.path] = folderCover
            }
            let art = folderCover ?? (await cacheAlbumArtwork(for: tracks[i]))
            if let art {
                coverByAlbum[albumID] = art
                tracks[i].artworkURL = art
            }
        }
    }

    private func localTrack(url: URL, kind: IndexedMediaKind, cfg: SourceConfig, size: Int?, modified: Date?) -> Track {
        let path = url.path
        let components = url.pathComponents
        let parsed = Self.parseTrack(url.deletingPathExtension().lastPathComponent)
        let album = components.count >= 2 ? components[components.count - 2] : cfg.name
        let artist = components.count >= 3 ? components[components.count - 3] : "Unknown Artist"
        return Track(
            id: "local-" + Self.stableHash(path),
            title: parsed.title.isEmpty ? url.lastPathComponent : parsed.title,
            artist: artist,
            album: album,
            albumID: "\(artist)::\(album)".lowercased(),
            artistID: artist.lowercased(),
            genre: "Unknown",
            durationSeconds: 0,
            trackNumber: parsed.number,
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

    private func refreshCacheStates() {
        let localIDs = Set(configs.filter { $0.proto == SourceProtocol.local.rawValue }.map(\.id))
        for index in allTracks.indices {
            if localIDs.contains(allTracks[index].sourceID) {
                allTracks[index].cacheState = .cached   // local files are always on-device
                continue
            }
            let isCached = FileManager.default.fileExists(atPath: Self.cacheFileURL(for: allTracks[index], cacheDir: cacheDir).path)
            if isCached {
                if allTracks[index].cacheState != .cached { allTracks[index].cacheState = .cached }
            } else if allTracks[index].cacheState == .cached {
                allTracks[index].cacheState = .remoteOnly
            }
        }
    }

    private static func cacheFileURL(for track: Track, cacheDir: URL) -> URL {
        let ext = (track.remotePath ?? track.folderPath as String) as NSString
        let pathExtension = ext.pathExtension.isEmpty ? "dat" : ext.pathExtension
        return cacheDir.appendingPathComponent("\(stableHash(track.id)).\(pathExtension)")
    }

    private func persistConfigs() {
        if let data = try? JSONEncoder().encode(configs) { try? data.write(to: configsURL, options: .atomic) }
    }

    private func persistLibrary() {
        if let data = try? JSONEncoder().encode(allTracks) { try? data.write(to: libraryURL, options: .atomic) }
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
