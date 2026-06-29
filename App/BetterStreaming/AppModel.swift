import Foundation
import Observation
import UIKit

/// Root application state. Owns the library data, the real playback engine, the
/// auto-cache controller, and global offline mode. Library data comes only from
/// the user's own sources via `LibraryService` (SMB/WebDAV scan → cache-first
/// playback). No demo/sample content.
@Observable
@MainActor
final class AppModel {
    let engine = PlaybackEngine()
    let autoCache = AutoCacheController()
    private let library = LibraryService()

    private(set) var sources: [LibrarySource] = []
    private(set) var tracks: [Track] = []
    private(set) var playlists: [Playlist] = []
    private(set) var recentlyPlayedIDs: [String] = []
    private(set) var isBootstrapping = true
    private(set) var isLoadingSavedLibrary = false
    private(set) var isScanning = false

    var offlineMode: Bool {
        didSet {
            UserDefaults.standard.set(offlineMode, forKey: "offlineMode.v1")
            reconcileAutoCache()
        }
    }

    private(set) var hasCompletedOnboarding: Bool
    var isNowPlayingPresented = false

    private var trackIndex: [String: Int] = [:]
    private var sourceConfigs: [SourceConfig] = []
    private var sourceHealth: [String: SourceHealth] = [:]
    private var sourceMessages: [String: String] = [:]
    private var startupMaintenanceTask: Task<Void, Never>?

    var hasSources: Bool { !sources.isEmpty }
    var hasLibrary: Bool { !tracks.isEmpty }
    var needsOnboarding: Bool { !isBootstrapping && !hasCompletedOnboarding && sources.isEmpty }

    init() {
        offlineMode = UserDefaults.standard.bool(forKey: "offlineMode.v1")
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarded.v1")
        wireEngine()
        wireAutoCache()
        Task { await bootstrap() }
    }

    // MARK: Bootstrap / scan

    private func bootstrap() async {
        let snapshot = await library.bootstrap()
        sourceConfigs = snapshot.configs
        tracks = snapshot.tracks
        rebuildIndex()
        for cfg in sourceConfigs where sourceHealth[cfg.id] == nil { sourceHealth[cfg.id] = .asleep }
        rebuildSources()
        isBootstrapping = false
        isLoadingSavedLibrary = !sourceConfigs.isEmpty
        schedulePostLaunchMaintenance()
    }

    private func schedulePostLaunchMaintenance() {
        startupMaintenanceTask?.cancel()
        guard !sourceConfigs.isEmpty else { return }

        startupMaintenanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }

            let saved = await self.library.loadSavedLibrary()
            guard !Task.isCancelled else { return }
            self.tracks = saved
            self.rebuildIndex()
            self.rebuildSources()
            self.isLoadingSavedLibrary = false
            self.reconcileAutoCache()

            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            let refreshed = await self.library.refreshCacheSnapshot()
            guard !Task.isCancelled else { return }
            self.tracks = refreshed
            self.rebuildIndex()
            self.rebuildSources()
        }
    }

    func rescan(_ sourceID: String) async {
        isScanning = true
        sourceMessages[sourceID] = "Scanning…"
        sourceHealth[sourceID] = .degraded
        rebuildSources()
        defer { isScanning = false }
        do {
            let updated = try await library.scan(sourceID: sourceID)
            tracks = updated
            rebuildIndex()
            sourceHealth[sourceID] = .online
            let sourceCount = updated.filter { $0.sourceID == sourceID }.count
            sourceMessages[sourceID] = sourceCount == 0 ? "No supported media found" : nil
        } catch let error as LibraryError {
            sourceHealth[sourceID] = (error.kind == .auth) ? .authFailed : .unreachable
            sourceMessages[sourceID] = error.message
        } catch {
            sourceHealth[sourceID] = .unreachable
            sourceMessages[sourceID] = error.localizedDescription
        }
        rebuildSources()
        reconcileAutoCache()
    }

    // MARK: Onboarding / sources

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "onboarded.v1")
    }

    func addSource(
        name: String,
        proto: SourceProtocol,
        host: String,
        port: Int? = nil,
        share: String,
        username: String? = nil,
        password: String? = nil,
        domain: String? = nil,
        rootPath: String = "/"
    ) {
        completeOnboarding()
        Task {
            let cfg = await library.addSource(
                name: name,
                proto: proto.rawValue,
                host: host,
                port: port ?? proto.defaultPort,
                share: share,
                username: username,
                domain: domain,
                password: password,
                rootPath: rootPath
            )
            sourceConfigs.append(cfg)
            sourceHealth[cfg.id] = .online
            rebuildSources()
            await rescan(cfg.id)
        }
    }

    /// Browse a server's folders with transient credentials (folder picker).
    func browseFolders(
        proto: SourceProtocol, host: String, port: Int?, share: String,
        username: String?, domain: String?, password: String?, path: String
    ) async -> Result<[RemoteFolder], LibraryError> {
        await library.listFolders(
            proto: proto.rawValue, host: host, port: port ?? proto.defaultPort, share: share,
            username: username, domain: domain, password: password, path: path
        )
    }

    /// Add an on-device / Files / iCloud folder as a source. Creates a
    /// security-scoped bookmark from the picked folder for durable access.
    func addLocalSource(name: String, folderURL: URL) {
        let accessed = folderURL.startAccessingSecurityScopedResource()
        let bookmark = try? folderURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        if accessed { folderURL.stopAccessingSecurityScopedResource() }
        guard let bookmark else { return }
        let b64 = bookmark.base64EncodedString()
        let path = folderURL.path
        completeOnboarding()
        Task {
            let cfg = await library.addLocalSource(name: name, bookmark: b64, displayPath: path)
            sourceConfigs.append(cfg)
            sourceHealth[cfg.id] = .online
            rebuildSources()
            await rescan(cfg.id)
        }
    }

    func removeSource(_ id: String) {
        Task { await library.removeSource(id) }
        sourceConfigs.removeAll { $0.id == id }
        sourceHealth[id] = nil
        tracks.removeAll { $0.sourceID == id }
        rebuildIndex()
        rebuildSources()
    }

    private func rebuildSources() {
        sources = sourceConfigs.map { cfg in
            let count = tracks.filter { $0.sourceID == cfg.id }.count
            let health = sourceHealth[cfg.id] ?? .asleep
            let message = sourceMessages[cfg.id]
            return LibrarySource(
                id: cfg.id,
                name: cfg.name,
                proto: SourceProtocol(rawValue: cfg.proto) ?? .smb,
                host: cfg.host,
                share: cfg.share,
                health: health,
                trackCount: count,
                folderCount: 0,
                lastScanLabel: message ?? (count > 0 ? "\(count) songs" : (health == .unreachable ? "Couldn’t connect" : "Not scanned")),
                speedLabel: "—"
            )
        }
    }

    private func rebuildIndex() {
        trackIndex = Dictionary(tracks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Derived collections

    func track(_ id: String) -> Track? {
        guard let i = trackIndex[id], tracks.indices.contains(i) else { return nil }
        return tracks[i]
    }

    func tracks(_ ids: [String]) -> [Track] { ids.compactMap(track) }

    var audioTracks: [Track] { tracks.filter { $0.kind == .audio } }
    var favorites: [Track] { tracks.filter(\.isFavorite) }
    var offlineTracks: [Track] { tracks.filter { $0.cacheState.isPlayableOffline } }

    var albums: [Album] {
        var grouped: [String: [Track]] = [:]
        for track in tracks where track.kind == .audio { grouped[track.albumID, default: []].append(track) }
        return grouped.values.compactMap { group -> Album? in
            guard let first = group.first else { return nil }
            let anyCached = group.contains { $0.cacheState.isPlayableOffline }
            let artworkURL = group.compactMap(\.artworkURL).first
            return Album(id: first.albumID, title: first.album, artist: first.artist, artistID: first.artistID,
                         year: nil, trackCount: group.count, cacheState: anyCached ? .cached : .remoteOnly, artworkURL: artworkURL)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var artists: [Artist] {
        var grouped: [String: [Track]] = [:]
        for track in tracks where track.kind == .audio { grouped[track.artistID, default: []].append(track) }
        return grouped.values.compactMap { group -> Artist? in
            guard let first = group.first else { return nil }
            return Artist(id: first.artistID, name: first.artist,
                          albumCount: Set(group.map(\.albumID)).count, trackCount: group.count, artworkURL: nil)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func tracks(forAlbum albumID: String) -> [Track] {
        tracks.filter { $0.albumID == albumID }.sorted(by: albumTrackSort)
    }

    func tracks(forArtist artistID: String) -> [Track] { tracks.filter { $0.artistID == artistID } }

    func tracks(forGenre genre: String) -> [Track] {
        audioTracks.filter { $0.genre.localizedCaseInsensitiveCompare(genre) == .orderedSame }
    }

    var recentlyPlayed: [Track] { recentlyPlayedIDs.compactMap(track) }
    var recentlyAddedAlbums: [Album] {
        var seen = Set<String>()
        var result: [Album] = []
        for track in tracks where track.kind == .audio {
            guard seen.insert(track.albumID).inserted else { continue }
            result.append(Album(
                id: track.albumID,
                title: track.album,
                artist: track.artist,
                artistID: track.artistID,
                year: nil,
                trackCount: 0,
                cacheState: track.cacheState.isPlayableOffline ? .cached : .remoteOnly,
                artworkURL: tracks.first(where: { $0.albumID == track.albumID && $0.artworkURL != nil })?.artworkURL
            ))
            if result.count == 8 { break }
        }
        return result
    }

    // MARK: Playback intents

    func play(_ track: Track, in context: [Track]) {
        let playable = playableContext(context)
        #if DEBUG
        print("BETTERSTREAMING_MODEL play_request title=\(track.title) ext=\(track.fileExtension) context=\(context.count) playable=\(playable.count) offline=\(offlineMode)")
        #endif
        engine.setShuffle(false)
        if let start = playable.firstIndex(where: { $0.id == track.id }) {
            engine.play(playable, startAt: start)
        } else {
            #if DEBUG
            print("BETTERSTREAMING_MODEL play_fallback_single title=\(track.title)")
            #endif
            engine.play([track], startAt: 0)
        }
    }

    func playAlbum(_ albumID: String, shuffled: Bool = false) {
        let list = playableContext(tracks(forAlbum: albumID))
        guard !list.isEmpty else { return }
        if shuffled { engine.playShuffled(list) }
        else { engine.setShuffle(false); engine.play(list, startAt: 0) }
    }

    func playPlaylist(_ playlist: Playlist, shuffled: Bool = false) {
        let list = playableContext(tracks(playlist.trackIDs))
        guard !list.isEmpty else { return }
        if shuffled { engine.playShuffled(list) }
        else { engine.setShuffle(false); engine.play(list, startAt: 0) }
    }

    func shuffleAll() {
        let list = playableContext(audioTracks)
        guard !list.isEmpty else { return }
        engine.playShuffled(list)
    }

    func playArtistRadio(_ artistID: String) {
        let list = playableContext(tracks(forArtist: artistID))
        guard !list.isEmpty else { return }
        engine.playShuffled(list)
    }

    func playGenreRadio(_ genre: String) {
        let list = playableContext(tracks(forGenre: genre))
        guard !list.isEmpty else { return }
        engine.playShuffled(list)
    }

    func similarTracks(to seed: Track) -> [Track] {
        let seedGenre = seed.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUsableGenre = !seedGenre.isEmpty && seedGenre.localizedCaseInsensitiveCompare("Unknown") != .orderedSame
        let scored = audioTracks.compactMap { track -> (Track, Int)? in
            var score = 0
            if track.id == seed.id { score += 10 }
            if track.artistID == seed.artistID { score += 6 }
            if hasUsableGenre && track.genre.localizedCaseInsensitiveCompare(seedGenre) == .orderedSame { score += 5 }
            if track.albumID == seed.albumID { score += 2 }
            guard score > 0 else { return nil }
            return (track, score)
        }
        let station = scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
            .map(\.0)
        return station.count >= 3 ? station : audioTracks
    }

    func playSimilarRadio(seed: Track) {
        let list = playableContext(similarTracks(to: seed))
        guard !list.isEmpty else { return }
        engine.playShuffled(list)
    }

    private func playableContext(_ context: [Track]) -> [Track] {
        guard offlineMode else { return context }
        return context.filter { $0.cacheState.isPlayableOffline }
    }

    private func albumTrackSort(_ lhs: Track, _ rhs: Track) -> Bool {
        let leftDisc = lhs.discNumber ?? 0
        let rightDisc = rhs.discNumber ?? 0
        if leftDisc != rightDisc { return leftDisc < rightDisc }

        let leftNumber = lhs.trackNumber ?? Self.leadingTrackNumber(lhs)
        let rightNumber = rhs.trackNumber ?? Self.leadingTrackNumber(rhs)
        switch (leftNumber, rightNumber) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private static func leadingTrackNumber(_ track: Track) -> Int? {
        let fileStem = ((track.remotePath ?? track.folderPath) as NSString).lastPathComponent as NSString
        let candidates = [fileStem.deletingPathExtension, track.title]
        for value in candidates {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = trimmed.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { continue }
            return number
        }
        return nil
    }

    // MARK: Mutations

    func isFavorite(_ id: String) -> Bool { track(id)?.isFavorite ?? false }

    func toggleFavorite(_ id: String) {
        guard let i = trackIndex[id] else { return }
        tracks[i].isFavorite.toggle()
        reconcileAutoCache()
    }

    func cacheState(_ id: String) -> CacheState { track(id)?.cacheState ?? .remoteOnly }

    func canManageDownload(_ id: String) -> Bool {
        guard let target = track(id) else { return false }
        return !isLocalSource(target.sourceID)
    }

    func download(_ id: String) {
        guard let i = trackIndex[id], canManageDownload(id) else { return }
        tracks[i].cacheState = .downloading
        let target = tracks[i]
        Task {
            let ok = await library.ensureCached(target)
            if let j = trackIndex[id] { tracks[j].cacheState = ok ? .cached : .failed }
        }
    }

    func removeDownload(_ id: String) {
        guard let i = trackIndex[id], canManageDownload(id) else { return }
        let target = tracks[i]
        Task { await library.evict(target) }
        tracks[i].cacheState = .remoteOnly
    }

    func toggleOfflineMode() { offlineMode.toggle() }

    // MARK: Search

    func searchResults(_ query: String) -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.artist.localizedCaseInsensitiveContains(trimmed)
                || $0.album.localizedCaseInsensitiveContains(trimmed)
                || $0.genre.localizedCaseInsensitiveContains(trimmed)
                || $0.folderPath.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: Wiring

    private func wireEngine() {
        engine.resolvePlayerItem = { [weak self] track in
            guard let self else { return nil }
            return await self.library.playableItem(for: track, offline: self.offlineMode)
        }
        engine.resolveAsset = { [weak self] track in
            guard let self else { return nil }
            return await self.library.playableURL(for: track, offline: self.offlineMode)
        }
        engine.loadArtwork = { [weak self] track in
            if let self, let data = await self.library.artworkData(for: track), let image = UIImage(data: data) {
                return image
            }
            return Artwork.image(for: track.albumID, glyph: track.kind == .video ? "film" : "music.note")
        }
        engine.onTrackStarted = { [weak self] track in
            guard let self else { return }
            self.notePlayed(track.id)
            Task {
                let cached = await self.library.isCached(track)
                if cached, let i = self.trackIndex[track.id] {
                    switch self.tracks[i].cacheState {
                    case .cached, .prefetched:
                        break
                    case .downloading:
                        self.tracks[i].cacheState = .cached
                    default:
                        self.tracks[i].cacheState = .prefetched
                    }
                }
                if let art = await self.library.cacheAlbumArtwork(for: track) {
                    for idx in self.tracks.indices
                    where self.tracks[idx].albumID == track.albumID && self.tracks[idx].artworkURL == nil {
                        self.tracks[idx].artworkURL = art
                    }
                }
            }
        }
    }

    private func wireAutoCache() {
        autoCache.applyPlan = { [weak self] plan in
            guard let self else { return }
            for id in plan.evict {
                guard let target = self.track(id) else { continue }
                await self.library.evict(target)
                if let i = self.trackIndex[id], self.tracks[i].cacheState == .prefetched {
                    self.tracks[i].cacheState = .remoteOnly
                }
            }
            var downloaded = 0
            for id in plan.keep where downloaded < 8 {
                guard let target = self.track(id), target.cacheState == .remoteOnly else { continue }
                if await self.library.ensureCached(target) {
                    if let i = self.trackIndex[id] { self.tracks[i].cacheState = .prefetched }
                    downloaded += 1
                }
            }
            self.autoCache.setUsage(await self.library.cachedBytes())
        }
    }

    private func notePlayed(_ id: String) {
        recentlyPlayedIDs.removeAll { $0 == id }
        recentlyPlayedIDs.insert(id, at: 0)
        if recentlyPlayedIDs.count > 40 { recentlyPlayedIDs.removeLast() }
        autoCache.recordPlay(id)
        reconcileAutoCache()
    }

    private func reconcileAutoCache() {
        let reachable = sourceHealth.values.contains { $0.isReachable }
        // Local-file tracks are always on-device; never auto-cache/evict them.
        let localIDs = Set(sourceConfigs.filter { $0.proto == SourceProtocol.local.rawValue }.map(\.id))
        let evictable = audioTracks.filter { !localIDs.contains($0.sourceID) }
        autoCache.scheduleReconcile(library: evictable, reachable: reachable && !offlineMode)
    }

    private func isLocalSource(_ sourceID: String) -> Bool {
        sourceConfigs.first(where: { $0.id == sourceID })?.proto == SourceProtocol.local.rawValue
    }
}
