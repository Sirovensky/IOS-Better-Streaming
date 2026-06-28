import AVFoundation
import BetterStreamingDomain
import Foundation
import LibraryIndexer
import RemoteFileSystem
import SMBRemote
#if canImport(WebDAVRemote)
import WebDAVRemote
#endif

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

        let request = ScanRequest(
            sourceID: SourceID(rawValue: UUID(uuidString: cfg.id) ?? UUID()),
            shareID: ShareID(rawValue: UUID(uuidString: cfg.shareID) ?? UUID()),
            rootPath: RemotePath(displayPath: cfg.rootPath),
            mode: .pathOnly
        )
        let scanner = RemoteLibraryScanner(fileSystem: client)
        let report = try await scanner.scan(request)
        let scanned = report.mediaFiles.map { track(from: $0, cfg: cfg) }

        allTracks.removeAll { $0.sourceID == sourceID }
        allTracks.append(contentsOf: scanned)
        refreshCacheStates()
        persistLibrary()
        return allTracks
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
        let password = KeychainStore.get(account: cfg.id)
        switch cfg.proto {
        case SourceProtocol.smb.rawValue:
            let configuration = SMBConnectionConfiguration(
                host: cfg.host, port: cfg.port, share: cfg.share,
                username: cfg.username, domain: cfg.domain
            )
            let auth = SMBAuthentication(username: cfg.username, domain: cfg.domain) { password }
            return SMBRemoteClient(configuration: configuration, authentication: auth)
        case SourceProtocol.webDAV.rawValue:
            #if canImport(WebDAVRemote)
            let scheme = cfg.port == 80 ? "http" : "https"
            guard let base = URL(string: "\(scheme)://\(cfg.host):\(cfg.port)/\(cfg.share)") else { return nil }
            return WebDAVRemoteClient(baseURL: base, username: cfg.username, password: password)
            #else
            return nil
            #endif
        default:
            // FTP / SFTP adapters not built yet.
            return nil
        }
    }

    private func track(from file: ScannedMediaFile, cfg: SourceConfig) -> Track {
        let identity = RemoteItemIdentity(
            sourceID: SourceID(rawValue: UUID(uuidString: cfg.id) ?? UUID()),
            shareID: ShareID(rawValue: UUID(uuidString: cfg.shareID) ?? UUID()),
            path: file.path,
            remoteFileID: file.remoteFileID,
            size: file.size,
            modifiedAt: file.modifiedAt
        )
        let components = file.path.remotePathComponents
        let title = (file.name as NSString).deletingPathExtension
        let album = components.count >= 2 ? components[components.count - 2] : cfg.name
        let artist = components.count >= 3 ? components[components.count - 3] : "Unknown Artist"

        return Track(
            id: identity.stableKey,
            title: title.isEmpty ? file.name : title,
            artist: artist,
            album: album,
            albumID: "\(artist)::\(album)".lowercased(),
            artistID: artist.lowercased(),
            genre: "Unknown",
            durationSeconds: 0,
            kind: file.mediaKind == .audio ? .audio : .video,
            cacheState: .remoteOnly,
            sourceID: cfg.id,
            sourceName: cfg.name,
            folderPath: file.path.displayPath,
            shareID: cfg.shareID,
            remotePath: file.path.displayPath,
            sizeBytes: file.size,
            modifiedAtEpoch: file.modifiedAt?.timeIntervalSince1970
        )
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
