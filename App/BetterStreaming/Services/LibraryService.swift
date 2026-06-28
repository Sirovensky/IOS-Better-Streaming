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
}

/// Bridges the Core package (SMB/WebDAV file access, recursive scan) to the
/// app's presentation models. Owns source configs, the on-disk media cache, and
/// cache-first playback resolution. Keeps all Core imports in this one file so
/// the App's own `MediaKind`/`CacheState` don't clash with Core's.
actor LibraryService {
    private let cacheDir: URL
    private let configsURL: URL
    private let libraryURL: URL

    private var configs: [SourceConfig] = []
    private var allTracks: [Track] = []
    private var didLoadFromDisk = false
    /// In-memory passwords for this session, set on add. Lets the first
    /// add→scan succeed even if the Keychain read lags/fails; Keychain remains
    /// the durable store for relaunches.
    private var sessionPasswords: [String: String] = [:]

    init() {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        cacheDir = caches.appendingPathComponent("Media", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        configsURL = support.appendingPathComponent("sources.json")
        libraryURL = support.appendingPathComponent("library.json")
    }

    // MARK: Load

    func bootstrap() -> (configs: [SourceConfig], tracks: [Track]) {
        loadFromDiskIfNeeded()
        return (configs, allTracks)
    }

    func refreshCacheSnapshot() -> [Track] {
        loadFromDiskIfNeeded()
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
        loadFromDiskIfNeeded()
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

    func removeSource(_ id: String) {
        loadFromDiskIfNeeded()
        configs.removeAll { $0.id == id }
        allTracks.removeAll { $0.sourceID == id }
        KeychainStore.delete(account: id)
        persistConfigs()
        persistLibrary()
    }

    func configList() -> [SourceConfig] {
        loadFromDiskIfNeeded()
        return configs
    }

    // MARK: Scan

    /// Recursively scan a source into tracks (path-first). Returns the full
    /// merged library so the caller can replace its state.
    func scan(sourceID: String) async throws -> [Track] {
        loadFromDiskIfNeeded()
        guard let cfg = configs.first(where: { $0.id == sourceID }),
              let client = makeClient(cfg) else { return allTracks }

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
        let title = (entry.name as NSString).deletingPathExtension
        let album = components.count >= 2 ? components[components.count - 2] : cfg.name
        let artist = components.count >= 3 ? components[components.count - 3] : "Unknown Artist"
        return Track(
            id: identity.stableKey,
            title: title.isEmpty ? entry.name : title,
            artist: artist,
            album: album,
            albumID: "\(artist)::\(album)".lowercased(),
            artistID: artist.lowercased(),
            genre: "Unknown",
            durationSeconds: 0,
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
        loadFromDiskIfNeeded()
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
        loadFromDiskIfNeeded()
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
        let local = cacheFileURL(for: track)
        guard FileManager.default.fileExists(atPath: local.path) else { return nil }
        let asset = AVURLAsset(url: local)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }

    // MARK: Internals

    private func loadFromDiskIfNeeded() {
        guard !didLoadFromDisk else { return }
        didLoadFromDisk = true
        if let data = try? Data(contentsOf: configsURL),
           let decoded = try? JSONDecoder().decode([SourceConfig].self, from: data) {
            configs = decoded
        }
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
        Self.refreshCacheStates(&allTracks, cacheDir: cacheDir)
    }

    private static func refreshCacheStates(_ tracks: inout [Track], cacheDir: URL) {
        for index in tracks.indices {
            let isCached = FileManager.default.fileExists(atPath: cacheFileURL(for: tracks[index], cacheDir: cacheDir).path)
            if isCached {
                if tracks[index].cacheState != .cached { tracks[index].cacheState = .cached }
            } else if tracks[index].cacheState == .cached {
                tracks[index].cacheState = .remoteOnly
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

    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
