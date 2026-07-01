import Foundation
import Observation
import UIKit

/// Root application state. Owns the library data, the real playback engine, the
/// auto-cache controller, and global offline mode. Library data comes only from
/// the user's own sources via `LibraryService` (SMB/WebDAV scan → cache-first
/// playback). No demo/sample content.
/// What the metadata editor sheet is currently editing. Stores ids (not value
/// copies) so the sheet always reads the live track/album.
enum MetadataEditTarget: Identifiable, Hashable {
    case track(String)
    case album(String)
    var id: String {
        switch self {
        case .track(let id): "track:" + id
        case .album(let id): "album:" + id
        }
    }
}

/// A shareable source definition: everything needed to re-add a remote source on
/// another device EXCEPT the password, which is never exported and is re-entered on
/// import. Serialised to a `.bettersource` JSON file / QR code (#7).
struct SharedSourceConfig: Codable, Hashable, Identifiable {
    var kind = "bettersource"
    var version = 1
    var name: String
    var proto: String
    var host: String
    var port: Int
    var share: String
    var username: String?
    var domain: String?
    var rootPath: String

    var id: String { "\(proto)://\(host):\(port)/\(share)?\(rootPath)" }
}

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
    /// Recent search queries (most-recent first), shown on the empty Search screen.
    private(set) var recentSearches: [String] = []
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
    /// When non-nil, the metadata editor sheet is presented for this track/album.
    var metadataEditTarget: MetadataEditTarget?

    private var trackIndex: [String: Int] = [:]
    /// Artist index, built once per library change in `rebuildIndex` — so artist
    /// queries are O(1) instead of re-running the credited-artist regex over the
    /// whole library on every access (which made a big artist's page take 5–10s).
    private var artistTrackIDs: [String: [String]] = [:]
    private var artistDisplayNames: [String: String] = [:]
    private var artistList: [Artist] = []
    /// Bumped on any change that affects derived collections (library scan, play
    /// counts, favorites, artwork/duration). `albums` and `libraryStats` cache their
    /// result keyed on this, so they recompute at most once per change instead of on
    /// every SwiftUI render — the per-render O(N) regroup/stats hitched large libraries.
    private(set) var libraryRevision = 0
    @ObservationIgnored private var _albumsCacheRev = -1
    @ObservationIgnored private var _albumsCache: [Album] = []
    @ObservationIgnored private var _needsAttentionCacheRev = -1
    @ObservationIgnored private var _needsAttentionCache: [Track] = []
    @ObservationIgnored private var _statsCacheRev = -1
    @ObservationIgnored private var _statsCache = LibraryStats(
        songs: 0, albums: 0, artists: 0, totalDurationSeconds: 0,
        totalPlays: 0, listenedSeconds: 0, favorites: 0)
    /// Lowercased "title artist album genre folder" per track id, rebuilt in
    /// `rebuildIndex`, so search is one substring scan per track instead of five
    /// locale-aware `contains` calls per track per keystroke.
    @ObservationIgnored private var searchHaystack: [String: String] = [:]
    /// Last track id counted as a play, so a stall-recovery re-resolve of the
    /// SAME track (which re-fires onTrackStarted) doesn't double-count it.
    private var lastNotedPlayID: String?
    private var sourceConfigs: [SourceConfig] = []
    private var sourceHealth: [String: SourceHealth] = [:]
    private var sourceMessages: [String: String] = [:]
    private var startupMaintenanceTask: Task<Void, Never>?
    private var artworkBackfillTask: Task<Void, Never>?
    @ObservationIgnored private var artworkGen = 0
    /// True while the artwork backfill is actively fetching covers — drives the
    /// status line + spinner in Settings. Written only here, observed by the UI.
    private(set) var isFetchingArtwork = false
    /// Resolved online artist photos by artist id (observed → artist header updates
    /// as they arrive). Backed by files in the persisted artwork dir.
    private(set) var artistImageURLs: [String: URL] = [:]
    /// Artist ids whose online-photo lookup already came up empty this session, so
    /// reopening their page doesn't re-hit the network every time.
    @ObservationIgnored private var attemptedArtistImageIDs: Set<String> = []
    /// Warms the next queued track so advancing/skip is instant. Cancelled and
    /// replaced whenever the current track changes.
    private var prefetchTask: Task<Void, Never>?

    var hasSources: Bool { !sources.isEmpty }
    var hasLibrary: Bool { !tracks.isEmpty }
    var needsOnboarding: Bool { !isBootstrapping && !hasCompletedOnboarding && sources.isEmpty }

#if DEBUG
    /// Bypasses onboarding and seeds a mock now-playing track for Simulator-only
    /// visual iteration on the player (no SMB needed). Triggered by `-uiPreview`.
    func debugPreviewNowPlaying(restorable: Bool = false) {
        hasCompletedOnboarding = true
        let mock = Track(
            id: "preview.track",
            title: "I Tame the Storm",
            artist: "Avantasia",
            album: "The Scarecrow",
            durationSeconds: 233,
            sourceID: "preview",
            sourceName: "Preview",
            folderPath: "Avantasia/The Scarecrow/I Tame the Storm.flac"
        )
        engine.debugSeedNowPlaying(mock, elapsed: 84, restorable: restorable)
    }
#endif

    /// Weak shared reference so a CarPlay scene (a separate UIKit scene with no
    /// SwiftUI environment) can reach the live model. Set on creation.
    static weak var shared: AppModel?

    init() {
        offlineMode = UserDefaults.standard.bool(forKey: "offlineMode.v1")
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarded.v1")
        recentlyPlayedIDs = UserDefaults.standard.stringArray(forKey: Self.recentlyPlayedKey) ?? []
        recentSearches = UserDefaults.standard.stringArray(forKey: Self.recentSearchesKey) ?? []
        loadPlaylists()
        AppModel.shared = self
        wireEngine()
        wireAutoCache()
        Task { await bootstrap() }
    }

    // MARK: Persisted playback state

    private static let recentlyPlayedKey = "recentlyPlayed.v1"
    private static let recentSearchesKey = "recentSearches.v1"

    /// Remember a search query (most-recent first, deduped, capped). Backs the
    /// Recent list on the empty Search screen.
    func recordSearch(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentSearches = Array(list.prefix(12))
        UserDefaults.standard.set(recentSearches, forKey: Self.recentSearchesKey)
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: Self.recentSearchesKey)
    }
    private static let playbackSnapshotKey = "playback.snapshot.v1"
    /// Last on-disk save of the playback position, for throttling the 0.5s tick.
    private var lastSnapshotSave = Date.distantPast

    /// Durable enough to survive exit / crash / OS-kill / update: the live queue,
    /// the current index, and the elapsed seconds.
    private struct PlaybackSnapshot: Codable {
        var queueIDs: [String]
        var index: Int
        var elapsed: Double
        var shuffle: Bool
        var repeatMode: String
    }

    /// Persist the current queue + position. `throttled` saves at most every 5s
    /// (called from the engine's 0.5s tick); pass `false` to force a save (track
    /// change, app background).
    private func savePlaybackSnapshot(throttled: Bool) {
        if throttled {
            let now = Date()
            guard now.timeIntervalSince(lastSnapshotSave) >= 5 else { return }
            lastSnapshotSave = now
        }
        let queue = engine.queue
        guard !queue.isEmpty, queue.indices.contains(engine.currentIndex) else {
            UserDefaults.standard.removeObject(forKey: Self.playbackSnapshotKey)
            return
        }
        let snapshot = PlaybackSnapshot(
            queueIDs: queue.map(\.id),
            index: engine.currentIndex,
            elapsed: engine.elapsed,
            shuffle: engine.shuffleEnabled,
            repeatMode: engine.repeatMode.rawValue
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.playbackSnapshotKey)
        }
    }

    /// Restore the last session's queue + position into the engine, PAUSED and
    /// without resolving any audio (the first play/seek loads it). No-op if
    /// something is already loaded or the saved tracks are gone.
    private func restorePlaybackIfNeeded() {
        guard engine.currentTrack == nil,
              let data = UserDefaults.standard.data(forKey: Self.playbackSnapshotKey),
              let snapshot = try? JSONDecoder().decode(PlaybackSnapshot.self, from: data) else { return }
        let queue = tracks(snapshot.queueIDs)
        guard !queue.isEmpty else { return }
        // The library may have changed; re-find the saved track in the restored
        // (possibly shorter) queue, else start at the head.
        let savedID = snapshot.queueIDs.indices.contains(snapshot.index) ? snapshot.queueIDs[snapshot.index] : nil
        let foundIndex = savedID.flatMap { id in queue.firstIndex { $0.id == id } }
        // If the exact saved track is gone, start the surviving queue at its head
        // from 0 — don't carry the old track's elapsed onto a different song.
        engine.restore(
            queue: queue,
            index: foundIndex ?? 0,
            elapsed: foundIndex != nil ? snapshot.elapsed : 0,
            shuffle: snapshot.shuffle,
            repeatMode: RepeatMode(rawValue: snapshot.repeatMode) ?? .off
        )
    }

    // MARK: Bootstrap / scan

    private func bootstrap() async {
        let snapshot = await library.bootstrap()
        sourceConfigs = snapshot.configs
        tracks = snapshot.tracks
        #if DEBUG
        await applyTestCredentialsIfNeeded()
        autoplayForTestingIfNeeded()
        #endif
        rebuildIndex()
        for cfg in sourceConfigs where sourceHealth[cfg.id] == nil { sourceHealth[cfg.id] = .asleep }
        rebuildSources()
        isBootstrapping = false
        isLoadingSavedLibrary = !sourceConfigs.isEmpty
        schedulePostLaunchMaintenance()
    }

    #if DEBUG
    /// Test-only: inject an SMB password from the launch environment so the
    /// Simulator (no Keychain) can authenticate against the real server during
    /// development. Inert unless `BETTERSTREAMING_TEST_SMB_PASSWORD` is set; the
    /// value lives only in memory and is never logged or persisted.
    private func applyTestCredentialsIfNeeded() async {
        guard let password = ProcessInfo.processInfo.environment["BETTERSTREAMING_TEST_SMB_PASSWORD"],
              !password.isEmpty else { return }
        for cfg in sourceConfigs where cfg.proto != SourceProtocol.local.rawValue {
            await library.debugSetSessionPassword(password, sourceID: cfg.id)
        }
    }

    /// Test-only: auto-play a track on launch (title substring in the env var, or
    /// the first track) so streaming can be exercised headlessly in the Simulator
    /// without UI taps. Inert unless `BETTERSTREAMING_TEST_AUTOPLAY` is set.
    private func autoplayForTestingIfNeeded() {
        guard let query = ProcessInfo.processInfo.environment["BETTERSTREAMING_TEST_AUTOPLAY"],
              !query.isEmpty else { return }
        Task { @MainActor in
            for _ in 0..<30 where audioTracks.isEmpty {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let pool = audioTracks
            guard let track = pool.first(where: { $0.title.localizedCaseInsensitiveContains(query) }) ?? pool.first
            else { return }
            streamLog.info("AUTOPLAY \(track.title, privacy: .public)")
            play(track, in: tracks(forAlbum: track.albumID))
        }
    }
    #endif

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
            self.restorePlaybackIfNeeded()   // re-select last track, paused at saved position
            self.reconcileAutoCache()
            self.backfillArtwork()

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
        // The scan and the artwork backfill share the one SMB connection; let the
        // scan have it (backfill re-runs at the end of the scan).
        artworkBackfillTask?.cancel()
        isScanning = true
        sourceMessages[sourceID] = "Scanning…"
        sourceHealth[sourceID] = .degraded
        rebuildSources()
        defer { isScanning = false }
        do {
            let updated = try await library.scan(sourceID: sourceID) { [weak self] count in
                Task { @MainActor in
                    guard let self, self.isScanning else { return }
                    self.sourceMessages[sourceID] = "Scanning… \(count) files"
                    self.rebuildSources()
                }
            }
            tracks = updated
            rebuildIndex()
            sourceHealth[sourceID] = .online
            let sourceCount = updated.filter { $0.sourceID == sourceID }.count
            if await library.lastScanIncomplete {
                // Some folders couldn't be listed — we kept the existing tracks
                // rather than pruning. Tell the user so they rescan when stable.
                sourceMessages[sourceID] = "Some folders couldn’t be read — library kept. Rescan on a stable connection."
            } else {
                sourceMessages[sourceID] = sourceCount == 0 ? "No supported media found" : nil
            }
        } catch let error as LibraryError {
            sourceHealth[sourceID] = (error.kind == .auth) ? .authFailed : .unreachable
            sourceMessages[sourceID] = error.message
        } catch {
            sourceHealth[sourceID] = .unreachable
            sourceMessages[sourceID] = error.localizedDescription
        }
        rebuildSources()
        reconcileAutoCache()
        backfillArtwork()
    }

    /// Progressively fetch album covers missing an on-disk file, straight from
    /// the remote source (folder cover or embedded ranged read). Runs in bounded
    /// passes so a large library fills in without one giant burst, and updates
    /// the UI as covers arrive. Skipped while offline (no source to read from).
    private func backfillArtwork(forceRetry: Bool = false) {
        artworkBackfillTask?.cancel()
        guard !offlineMode, !sourceConfigs.isEmpty else { return }
        artworkGen &+= 1
        let gen = artworkGen
        isFetchingArtwork = true
        artworkBackfillTask = Task { [weak self] in
            guard let self else { return }
            // Only clear the flag if a newer backfill hasn't superseded this one —
            // a cancelled-but-still-draining task must not turn off the spinner the
            // new task just turned on.
            defer { if self.artworkGen == gen { self.isFetchingArtwork = false } }
            // A manual rescan forgets prior per-session failures so cover-less albums
            // are tried again (e.g. right after the user enables online artwork).
            if forceRetry { await self.library.resetArtworkAttempts() }
            for _ in 0..<12 {
                if Task.isCancelled { return }
                let map = await self.library.backfillAlbumArtwork(for: self.tracks)
                if Task.isCancelled || map.isEmpty { return }
                for i in self.tracks.indices where self.tracks[i].artworkURL == nil {
                    if let url = map[self.tracks[i].albumID] { self.tracks[i].artworkURL = url }
                }
                self.libraryRevision &+= 1
            }
        }
    }

    /// Albums with no cover yet (no on-disk file, no fetched URL). Drives the
    /// artwork status line in Settings.
    var albumsMissingArtworkCount: Int {
        albums.reduce(into: 0) { count, album in
            if album.artworkURL == nil { count += 1 }
        }
    }

    /// User-triggered "fetch missing covers" — re-runs the backfill on demand and
    /// forces a retry of albums that came up empty earlier this session (e.g. after
    /// the user turns online artwork on).
    func refreshArtwork() {
        backfillArtwork(forceRetry: true)
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

    // MARK: Source config sharing (#7)

    /// A shareable config for a remote source, or nil for local/Files sources
    /// (they rely on a device-only security-scoped bookmark that can't transfer).
    /// The password is never included — `SourceConfig` doesn't even hold it.
    func exportableSource(_ id: String) -> SharedSourceConfig? {
        guard let cfg = sourceConfigs.first(where: { $0.id == id }),
              cfg.bookmark == nil else { return nil }
        return SharedSourceConfig(
            name: cfg.name, proto: cfg.proto, host: cfg.host, port: cfg.port,
            share: cfg.share, username: cfg.username, domain: cfg.domain, rootPath: cfg.rootPath
        )
    }

    /// Add a source from an imported shared config plus a freshly-entered password.
    func importSource(_ shared: SharedSourceConfig, password: String?) {
        guard let proto = SourceProtocol(rawValue: shared.proto) else { return }
        addSource(
            name: shared.name, proto: proto, host: shared.host, port: shared.port,
            share: shared.share, username: shared.username, password: password,
            domain: shared.domain, rootPath: shared.rootPath
        )
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
        // Stop playback if the current track (or queue) belongs to the removed
        // source — otherwise the live stream would revive its just-disconnected
        // connection, and the queue would point at tracks that no longer exist.
        if engine.queue.contains(where: { $0.sourceID == id }) {
            engine.clearQueue()
            lastNotedPlayID = nil
        }
        Task { await library.removeSource(id) }
        sourceConfigs.removeAll { $0.id == id }
        sourceHealth[id] = nil
        tracks.removeAll { $0.sourceID == id }
        rebuildIndex()
        rebuildSources()
    }

    /// App moved to the background: tear down idle background (scan/artwork/
    /// download) connections so the server's session table is freed. The stream
    /// connection is kept so background audio keeps playing; it and any torn-down
    /// background client reconnect lazily on next use.
    func enteredBackground() {
        savePlaybackSnapshot(throttled: false)   // survive an OS-kill while suspended
        autoCache.flushStats()                   // flush debounced listening stats
        Task { await library.handleEnteredBackground() }
    }

    private func rebuildSources() {
        sources = sourceConfigs.map { cfg in
            let srcTracks = tracks.filter { $0.sourceID == cfg.id }
            let count = srcTracks.count
            let folders = Set(srcTracks.map { track -> String in
                MetadataGrouping.albumFolderComponents(forPath: track.remotePath ?? track.folderPath)
                    .joined(separator: "/")
            }).count
            let totalBytes = srcTracks.reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
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
                folderCount: folders,
                lastScanLabel: message ?? (count > 0 ? "\(count) songs" : (health == .unreachable ? "Couldn’t connect" : "Not scanned")),
                speedLabel: "—",
                sizeLabel: totalBytes > 0 ? AutoCacheController.byteLabel(totalBytes) : "—",
                basePath: cfg.proto == SourceProtocol.local.rawValue ? "" : cfg.rootPath
            )
        }
    }

    private func rebuildIndex() {
        trackIndex = Dictionary(tracks.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        // Build the artist index here (once), running the credited-artist regex a
        // single time per track instead of per query.
        var trackIDs: [String: [String]] = [:]
        var names: [String: String] = [:]
        var albumsByArtist: [String: Set<String>] = [:]
        for track in tracks where track.kind == .audio {
            for name in MetadataGrouping.creditedArtists(track.artist) {
                let id = MetadataGrouping.normalizeKey(name)
                guard !id.isEmpty else { continue }
                trackIDs[id, default: []].append(track.id)
                if names[id] == nil { names[id] = name }
                albumsByArtist[id, default: []].insert(track.albumID)
            }
        }
        artistTrackIDs = trackIDs
        artistDisplayNames = names
        artistList = trackIDs.keys.map { id in
            Artist(id: id, name: names[id] ?? id,
                   albumCount: albumsByArtist[id]?.count ?? 0,
                   trackCount: trackIDs[id]?.count ?? 0, artworkURL: nil)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var haystack: [String: String] = [:]
        haystack.reserveCapacity(tracks.count)
        for track in tracks {
            haystack[track.id] = "\(track.title) \(track.artist) \(track.album) \(track.genre) \(track.folderPath)".lowercased()
        }
        searchHaystack = haystack
        libraryRevision &+= 1   // invalidate albums/stats caches
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
        let rev = libraryRevision   // registers observation; recompute once per change
        if _albumsCacheRev != rev { _albumsCache = computeAlbums(); _albumsCacheRev = rev }
        return _albumsCache
    }

    private func computeAlbums() -> [Album] {
        var grouped: [String: [Track]] = [:]
        for track in tracks where track.kind == .audio { grouped[track.albumID, default: []].append(track) }
        return grouped.values.compactMap { group -> Album? in
            guard let first = group.first else { return nil }
            let anyCached = group.contains { $0.cacheState.isPlayableOffline }
            let artworkURL = group.compactMap(\.artworkURL).first
            // Display artist is the album's shared primary artist (or "Various
            // Artists"), not whichever feat.-credited track happens to be first.
            let displayArtist = MetadataGrouping.albumDisplayArtist(from: group.map(\.artist))
            return Album(id: first.albumID, title: first.album, artist: displayArtist, artistID: first.artistID,
                         year: nil, trackCount: group.count, cacheState: anyCached ? .cached : .remoteOnly, artworkURL: artworkURL)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// One entry per individual credited artist. Built in `rebuildIndex` (O(1) here).
    var artists: [Artist] { artistList }

    /// Display name for an artist id (the first-seen credit spelling).
    func artistName(_ artistID: String) -> String? { artistDisplayNames[artistID] }

    /// Read-only library stats for the Home "Your Library" card (no setup/actions).
    struct LibraryStats {
        var songs: Int
        var albums: Int
        var artists: Int
        var totalDurationSeconds: Double
        var totalPlays: Int
        var listenedSeconds: Double
        var favorites: Int
    }

    var libraryStats: LibraryStats {
        let rev = libraryRevision   // registers observation; recompute once per change
        if _statsCacheRev != rev { _statsCache = computeLibraryStats(); _statsCacheRev = rev }
        return _statsCache
    }

    private func computeLibraryStats() -> LibraryStats {
        let audio = audioTracks
        var totalDuration = 0.0
        var totalPlays = 0
        var listened = 0.0
        var favorites = 0
        for track in audio {
            if track.durationSeconds > 0 { totalDuration += track.durationSeconds }
            let plays = autoCache.stat(for: track.id).playCount
            totalPlays += plays
            if track.durationSeconds > 0 { listened += Double(plays) * track.durationSeconds }
            if track.isFavorite { favorites += 1 }
        }
        return LibraryStats(
            songs: audio.count,
            albums: Set(audio.map(\.albumID)).count,
            artists: artists.count,
            totalDurationSeconds: totalDuration,
            totalPlays: totalPlays,
            listenedSeconds: listened,
            favorites: favorites
        )
    }

    func tracks(forAlbum albumID: String) -> [Track] {
        tracks.filter { $0.albumID == albumID }.sorted(by: albumTrackSort)
    }

    /// Distinct credited performers on an album, in first-seen order — so a
    /// "Various Artists" album (opera cast, compilation) can list every singer to
    /// open instead of dead-ending on whoever happened to be first. Each maps to
    /// the same artist id the index uses, so the rows route to a real artist page.
    func creditedArtists(forAlbum albumID: String) -> [Artist] {
        let byID = Dictionary(artistList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var result: [Artist] = []
        for track in tracks(forAlbum: albumID) {
            for name in MetadataGrouping.creditedArtists(track.artist) {
                let id = MetadataGrouping.normalizeKey(name)
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                result.append(byID[id] ?? Artist(id: id, name: artistDisplayNames[id] ?? name,
                                                 albumCount: 0, trackCount: artistTrackIDs[id]?.count ?? 0,
                                                 artworkURL: nil))
            }
        }
        return result
    }

    /// Fetch + apply an album cover on demand (folder → embedded → online, per the
    /// source and the online-artwork setting). Called when an album with no art is
    /// opened, so the user doesn't have to wait for a background backfill pass.
    func ensureAlbumArtwork(_ albumID: String) {
        let albumTracks = tracks(forAlbum: albumID)
        guard let representative = albumTracks.first,
              !albumTracks.contains(where: { $0.artworkURL != nil }) else { return }
        Task { [weak self] in
            guard let self, let url = await self.library.remoteAlbumArtwork(for: representative) else { return }
            for i in self.tracks.indices
            where self.tracks[i].albumID == albumID && self.tracks[i].artworkURL == nil {
                self.tracks[i].artworkURL = url
            }
            self.libraryRevision &+= 1
        }
    }

    func tracks(forArtist artistID: String) -> [Track] {
        (artistTrackIDs[artistID] ?? []).compactMap(track)
    }

    /// Cached online artist photo for the header, or nil (→ placeholder glyph).
    func artistImage(_ artistID: String) -> URL? { artistImageURLs[artistID] }

    /// Fetch + cache an artist photo from the user's enabled sources, once. The
    /// cached-file check inside the library means a previously fetched photo shows
    /// offline too; a genuine miss is remembered for the session so the page open
    /// doesn't re-hit the network each time.
    func ensureArtistImage(_ artistID: String) {
        guard artistImageURLs[artistID] == nil, !attemptedArtistImageIDs.contains(artistID) else { return }
        let sources = ArtistImageSource.enabled
        guard !sources.isEmpty, let name = artistName(artistID) ?? tracks(forArtist: artistID).first?.artist else { return }
        attemptedArtistImageIDs.insert(artistID)
        Task { [weak self] in
            guard let self else { return }
            if let url = await self.library.artistImageURL(forArtist: artistID, name: name, sources: sources) {
                self.artistImageURLs[artistID] = url
            }
        }
    }

    /// Forget this session's artist-photo misses so a user-triggered retry (e.g.
    /// after enabling a source) re-fetches.
    func resetArtistImageAttempts() {
        attemptedArtistImageIDs.removeAll()
    }

    /// Per-artist dominant genre family. An artist whose tracks are tagged with a
    /// mix of sub-genres (Amaranthe: rock / symphonic metal / heavy metal) gets
    /// one consensus family, so a station pulls their whole catalog.
    var genreConsensusByArtist: [String: String] {
        var counts: [String: [String: Int]] = [:]
        for track in tracks where track.kind == .audio {
            guard let g = MetadataGrouping.canonicalGenre(track.genre) else { continue }
            counts[track.artistID, default: [:]][g, default: 0] += 1
        }
        var result: [String: String] = [:]
        for (artist, byGenre) in counts {
            if let best = byGenre.max(by: { $0.value < $1.value })?.key { result[artist] = best }
        }
        return result
    }

    /// Canonical genres present in the library (sorted), for the Songs filter.
    var availableGenres: [String] {
        Set(audioTracks.compactMap { MetadataGrouping.canonicalGenre($0.genre) }).sorted()
    }

    func tracks(forGenre genre: String) -> [Track] {
        let target = MetadataGrouping.canonicalGenre(genre) ?? MetadataGrouping.normalizeKey(genre)
        let consensus = genreConsensusByArtist
        return audioTracks.filter { track in
            let effective = consensus[track.artistID] ?? MetadataGrouping.canonicalGenre(track.genre)
            return effective == target
        }
    }

    /// Canonical genre stations for Radio, by track count. Uses artist-consensus
    /// genres so sub-genre tagging noise doesn't fragment a band across stations.
    func genreStations(minTracks: Int = 2, limit: Int = 14) -> [(name: String, trackCount: Int)] {
        let consensus = genreConsensusByArtist
        var counts: [String: Int] = [:]
        for track in audioTracks {
            guard let g = consensus[track.artistID] ?? MetadataGrouping.canonicalGenre(track.genre) else { continue }
            counts[g, default: 0] += 1
        }
        return counts
            .filter { $0.value >= minTracks }
            .map { (name: $0.key, trackCount: $0.value) }
            .sorted { $0.trackCount != $1.trackCount ? $0.trackCount > $1.trackCount : $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }

    var recentlyPlayed: [Track] { recentlyPlayedIDs.compactMap(track) }
    var recentlyAddedAlbums: [Album] {
        var grouped: [String: [Track]] = [:]
        for track in tracks where track.kind == .audio { grouped[track.albumID, default: []].append(track) }
        return grouped.values.compactMap { group -> (album: Album, recency: Double)? in
            guard let first = group.first else { return nil }
            let recency = group.compactMap(\.modifiedAtEpoch).max() ?? 0
            let anyCached = group.contains { $0.cacheState.isPlayableOffline }
            let album = Album(
                id: first.albumID,
                title: first.album,
                artist: MetadataGrouping.albumDisplayArtist(from: group.map(\.artist)),
                artistID: first.artistID,
                year: nil,
                trackCount: group.count,
                cacheState: anyCached ? .cached : .remoteOnly,
                artworkURL: group.compactMap(\.artworkURL).first
            )
            return (album, recency)
        }
        .sorted { $0.recency > $1.recency }
        .prefix(8)
        .map(\.album)
    }

    // MARK: Rediscovery shelves (Home)

    /// Audio you imported but never played. Sorted by a per-session-stable key so
    /// the rail spreads across the library yet doesn't reshuffle while scrolling.
    var haveNotHeard: [Track] {
        audioTracks
            .filter { autoCache.stat(for: $0.id).playCount == 0 }
            .sorted { $0.id.hashValue < $1.id.hashValue }
            .prefix(12)
            .map { $0 }
    }

    /// Tracks you used to play but haven't returned to in 90+ days, ranked so
    /// former favourites (more historical plays) surface first.
    var buriedTreasure: [Track] {
        let cutoff = Date().timeIntervalSince1970 - 90 * 24 * 3600
        return audioTracks
            .compactMap { track -> (Track, Double)? in
                let stat = autoCache.stat(for: track.id)
                guard stat.playCount > 0, stat.lastPlayedAtEpoch > 0,
                      stat.lastPlayedAtEpoch < cutoff else { return nil }
                return (track, log2(Double(stat.playCount) + 1))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
            .map(\.0)
    }

    /// Albums added to the library on this calendar day in a previous year.
    var onThisDayAlbums: [Album] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.dateComponents([.month, .day], from: now)
        let currentYear = calendar.component(.year, from: now)
        var grouped: [String: [Track]] = [:]
        for track in tracks where track.kind == .audio {
            guard let epoch = track.modifiedAtEpoch else { continue }
            let comps = calendar.dateComponents([.month, .day, .year], from: Date(timeIntervalSince1970: epoch))
            guard comps.month == today.month, comps.day == today.day,
                  let year = comps.year, year < currentYear else { continue }
            grouped[track.albumID, default: []].append(track)
        }
        return grouped.values.compactMap { group -> Album? in
            guard let first = group.first else { return nil }
            let anyCached = group.contains { $0.cacheState.isPlayableOffline }
            return Album(
                id: first.albumID, title: first.album,
                artist: MetadataGrouping.albumDisplayArtist(from: group.map(\.artist)),
                artistID: first.artistID, year: nil, trackCount: group.count,
                cacheState: anyCached ? .cached : .remoteOnly,
                artworkURL: group.compactMap(\.artworkURL).first
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Most-played tracks over the last 30 days, from the windowed play log.
    var topThisMonth: [Track] {
        autoCache.topPlayed(sinceDays: 30, limit: 12).compactMap(track)
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

    /// Lyrics for a track (`.lrc` sidecar), synced when timestamped.
    func lyrics(for track: Track) async -> [LyricsLine]? { await library.lyrics(for: track) }

    func playPlaylist(_ playlist: Playlist, shuffled: Bool = false) {
        let list = playableContext(tracks(playlist.trackIDs))
        guard !list.isEmpty else { return }
        if shuffled { engine.playShuffled(list) }
        else { engine.setShuffle(false); engine.play(list, startAt: 0) }
    }

    // MARK: Playlists (user-created + .m3u import)

    private static let playlistsKey = "playlists.v1"

    func loadPlaylists() {
        guard let data = UserDefaults.standard.data(forKey: Self.playlistsKey),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        // Keep only user playlists (not live folders, which are derived).
        playlists = decoded
    }

    private func persistPlaylists() {
        let userPlaylists = playlists.filter { !$0.isLiveFolder }
        if let data = try? JSONEncoder().encode(userPlaylists) {
            UserDefaults.standard.set(data, forKey: Self.playlistsKey)
        }
    }

    @discardableResult
    func createPlaylist(name: String, trackIDs: [String] = []) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(
            id: UUID().uuidString,
            name: trimmed.isEmpty ? "New Playlist" : trimmed,
            subtitle: "Playlist",
            trackIDs: trackIDs,
            artworkURLs: artworkURLs(for: trackIDs),
            isLiveFolder: false
        )
        playlists.insert(playlist, at: 0)
        persistPlaylists()
        return playlist
    }

    func renamePlaylist(_ id: String, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists[i].name = trimmed
        persistPlaylists()
    }

    func deletePlaylist(_ id: String) {
        playlists.removeAll { $0.id == id }
        persistPlaylists()
    }

    func addToPlaylist(_ playlistID: String, trackIDs newIDs: [String]) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        // Append, skipping ones already present (preserve order).
        let existing = Set(playlists[i].trackIDs)
        playlists[i].trackIDs.append(contentsOf: newIDs.filter { !existing.contains($0) })
        playlists[i].artworkURLs = artworkURLs(for: playlists[i].trackIDs)
        persistPlaylists()
    }

    func removeFromPlaylist(_ playlistID: String, at offsets: IndexSet) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].trackIDs.remove(atOffsets: offsets)
        playlists[i].artworkURLs = artworkURLs(for: playlists[i].trackIDs)
        persistPlaylists()
    }

    private func artworkURLs(for trackIDs: [String]) -> [URL] {
        trackIDs.prefix(4).compactMap { track($0)?.artworkURL }
    }

    /// Import a `.m3u`/`.m3u8` playlist file: match each referenced path to a
    /// library track by filename (case-insensitive), preserving order. Creates a
    /// playlist named after the file. Returns the new playlist, or nil if nothing
    /// matched.
    @discardableResult
    func importM3U(from url: URL) -> Playlist? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let text = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return nil }
        // Index library tracks by lowercased filename for matching.
        var byFilename: [String: String] = [:]   // filename -> trackID
        for t in tracks {
            let file = ((t.remotePath ?? t.folderPath) as NSString).lastPathComponent.lowercased()
            if !file.isEmpty, byFilename[file] == nil { byFilename[file] = t.id }
        }
        var matched: [String] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let file = (line as NSString).lastPathComponent.lowercased()
            if let id = byFilename[file], seen.insert(id).inserted { matched.append(id) }
        }
        guard !matched.isEmpty else { return nil }
        let name = (url.lastPathComponent as NSString).deletingPathExtension
        return createPlaylist(name: name, trackIDs: matched)
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
        let station = progressiveStation(seed: seed)
        guard !station.isEmpty else { return }
        // Station defines its own order (seed first, then widening genre bands);
        // play in order, not reshuffled.
        engine.setShuffle(false)
        engine.play(station, startAt: 0)
    }

    /// Build a similar-station queue that starts on the exact seed, then the same
    /// genre family, then progressively widens to ADJACENT families (Rock → Metal
    /// → … but never EDM), shuffled within each distance band. Stops once no
    /// in-family genres remain. Falls back to artist/album affinity for
    /// unknown-genre tracks.
    private func progressiveStation(seed: Track, maxDistance: Int = 2, limit: Int = 300) -> [Track] {
        let consensus = genreConsensusByArtist
        func family(_ t: Track) -> String? { consensus[t.artistID] ?? MetadataGrouping.canonicalGenre(t.genre) }
        let seedFamily = family(seed)
        var bands: [Int: [Track]] = [:]
        for track in playableContext(audioTracks) where track.id != seed.id {
            let distance: Int
            if let sf = seedFamily, let tf = family(track) {
                guard let d = MetadataGrouping.genreFamilyDistance(sf, tf, max: maxDistance) else { continue }
                distance = d
            } else {
                // Unknown genre on seed or track → use only artist/album affinity.
                if track.artistID == seed.artistID { distance = 0 }
                else if track.albumID == seed.albumID { distance = 1 }
                else { continue }
            }
            bands[distance, default: []].append(track)
        }
        var ordered: [Track] = []
        // Seed first only when it's actually playable (the tile's preview song).
        if playableContext([seed]).isEmpty == false { ordered.append(seed) }
        for distance in 0...maxDistance {
            guard var band = bands[distance], !band.isEmpty else { continue }
            band.removeAll { $0.id == seed.id }
            band.shuffle()
            ordered.append(contentsOf: band)
        }
        if ordered.isEmpty { return playableContext(audioTracks).shuffled() }
        return Array(ordered.prefix(limit))
    }

    // MARK: Sleep timer

    /// When the running minute-based sleep timer will pause playback (nil if off).
    private(set) var sleepTimerEnd: Date?
    private var sleepTimerTask: Task<Void, Never>?

    var sleepTimerArmed: Bool { sleepTimerEnd != nil || engine.stopAtTrackEnd }

    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        sleepTimerEnd = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.engine.pause()
            self.sleepTimerEnd = nil
        }
    }

    /// Pause when the current track finishes.
    func sleepAtEndOfTrack() {
        cancelSleepTimer()
        engine.stopAtTrackEnd = true
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEnd = nil
        engine.stopAtTrackEnd = false
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
        let value = !tracks[i].isFavorite
        tracks[i].isFavorite = value
        Task { await library.setFavorite(value, forTrack: id) }
        reconcileAutoCache()
    }

    // MARK: Metadata repair

    /// Apply a user metadata edit to one track. Recomputes the derived album/artist
    /// grouping keys (so a corrected album/artist regroups correctly) and rebuilds
    /// the indexes. The change is persisted as a non-destructive override that
    /// survives a tag rescan.
    func editTrackMetadata(_ id: String, title: String, artist: String, album: String, genre: String) {
        guard let i = trackIndex[id] else { return }
        tracks[i].title = title
        tracks[i].artist = artist
        tracks[i].album = album
        tracks[i].genre = genre
        tracks[i].albumID = MetadataGrouping.albumID(path: tracks[i].remotePath ?? tracks[i].folderPath, album: album)
        tracks[i].artistID = MetadataGrouping.artistID(artist)
        Task { await library.setMetadataOverride(forTrack: id, title: title, artist: artist, album: album, genre: genre) }
        rebuildIndex()
    }

    /// Apply album/artist/genre to every track in an album in one pass (one index
    /// rebuild), e.g. fixing a misnamed album for the whole record at once.
    func editAlbumMetadata(_ albumID: String, album: String, artist: String, genre: String) {
        let targets = tracks.indices.filter { tracks[$0].albumID == albumID }
        guard !targets.isEmpty else { return }
        for i in targets {
            let id = tracks[i].id
            tracks[i].album = album
            tracks[i].artist = artist
            tracks[i].genre = genre
            tracks[i].albumID = MetadataGrouping.albumID(path: tracks[i].remotePath ?? tracks[i].folderPath, album: album)
            tracks[i].artistID = MetadataGrouping.artistID(artist)
            Task { await library.setMetadataOverride(forTrack: id, title: nil, artist: artist, album: album, genre: genre) }
        }
        rebuildIndex()
    }

    /// Drop a track's override and restore the file-scanned values.
    func revertTrackMetadata(_ id: String) {
        Task {
            guard let restored = await library.clearMetadataOverride(forTrack: id),
                  let i = trackIndex[id] else { return }
            tracks[i].title = restored.title
            tracks[i].artist = restored.artist
            tracks[i].album = restored.album
            tracks[i].genre = restored.genre
            tracks[i].albumID = MetadataGrouping.albumID(path: tracks[i].remotePath ?? tracks[i].folderPath, album: restored.album)
            tracks[i].artistID = MetadataGrouping.artistID(restored.artist)
            rebuildIndex()
        }
    }

    /// Tracks whose metadata is genuinely broken: missing artist, an album that
    /// fell back to the source name (no real album tag), or an empty title. Backs
    /// the review queue. A missing GENRE is deliberately NOT flagged — most files
    /// lack one, and it's low value, so flagging it drowned the queue.
    var metadataNeedsAttention: [Track] {
        // Cached revision-keyed: this is read in SettingsView.body, which also
        // re-evaluates on every EQ-slider frame — an uncached O(N) scan over ~3k
        // tracks there was a per-frame hitch.
        let rev = libraryRevision
        if _needsAttentionCacheRev != rev {
            _needsAttentionCache = audioTracks.filter { track in
                track.artist == "Unknown Artist"
                    || track.artist == "Unknown"
                    || track.album == track.sourceName
                    || track.title.trimmingCharacters(in: .whitespaces).isEmpty
            }
            _needsAttentionCacheRev = rev
        }
        return _needsAttentionCache
    }

    /// Bulk-infer artist/album/title for broken tracks from their file names and
    /// folder layout (Artist/Album/NN Title.ext, or "Artist - Title" filenames).
    /// Fills ONLY broken fields — never overwrites a real tag — writes reversible
    /// per-track overrides in one batched pass, and rebuilds the index once.
    /// Returns the count changed. The inference runs off the main actor (it's a
    /// pure scan over the whole library), so the UI stays responsive.
    @discardableResult
    func autoFixMetadataFromFiles() async -> Int {
        let snapshot = tracks
        let fixes = await Task.detached(priority: .userInitiated) {
            AppModel.computeAutoFixEdits(snapshot)
        }.value
        guard !fixes.isEmpty else { return 0 }

        // Apply to the in-memory copy by an id→index map (O(N+edits)).
        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(tracks.count)
        for (i, t) in tracks.enumerated() { indexByID[t.id] = i }
        for fix in fixes {
            guard let i = indexByID[fix.id] else { continue }
            if let title = fix.title { tracks[i].title = title }
            if let artist = fix.artist {
                tracks[i].artist = artist
                tracks[i].artistID = MetadataGrouping.artistID(artist)
            }
            if let album = fix.album {
                tracks[i].album = album
                tracks[i].albumID = MetadataGrouping.albumID(path: tracks[i].remotePath ?? tracks[i].folderPath, album: album)
            }
        }
        await library.applyMetadataOverrides(fixes)
        rebuildIndex()
        return fixes.count
    }

    /// Pure inference used by `autoFixMetadataFromFiles` — `nonisolated static` so
    /// it can run off the main actor over a `Track` snapshot. Each returned fix has
    /// non-nil values ONLY for the fields that were broken.
    nonisolated private static func computeAutoFixEdits(_ tracks: [Track]) -> [MetadataAutoFix] {
        var fixes: [MetadataAutoFix] = []
        for t in tracks where t.kind == .audio {
            let path = t.remotePath ?? t.folderPath
            let comps = path.split(separator: "/").map(String.init)
            guard let fileName = comps.last else { continue }
            let stem = (fileName as NSString).deletingPathExtension
            let parsed = LibraryService.parseTrack(stem)
            let split = LibraryService.splitArtistTitle(parsed.title)
            // Disc-stripped folder chain ([…, Artist, Album]) — never picks up a
            // "CD1"/"Disc 2" subfolder as the album or the album as the artist.
            let folders = MetadataGrouping.albumFolderComponents(forPath: path)

            var newArtist: String?
            var newAlbum: String?
            var newTitle: String?

            // Artist: from an "Artist - Title" filename, else the folder above the album.
            if t.artist == "Unknown Artist" || t.artist == "Unknown" {
                if let inferred = split.artist { newArtist = inferred }
                else if folders.count >= 2 { newArtist = folders[folders.count - 2] }
            }
            // Album: the album folder, when the album fell back to the source name.
            if t.album == t.sourceName, let albumFolder = folders.last {
                newAlbum = albumFolder
            }
            // Title: ONLY when the current title is blank. A non-empty title is a
            // real tag and must never be overwritten by a filename guess.
            if t.title.trimmingCharacters(in: .whitespaces).isEmpty, let inferredTitle = split.title {
                newTitle = inferredTitle
            }
            if newArtist != nil || newAlbum != nil || newTitle != nil {
                fixes.append(MetadataAutoFix(id: t.id, title: newTitle, artist: newArtist, album: newAlbum))
            }
        }
        return fixes
    }

    func cacheState(_ id: String) -> CacheState { track(id)?.cacheState ?? .remoteOnly }

    func canManageDownload(_ id: String) -> Bool {
        guard let target = track(id) else { return false }
        return !isLocalSource(target.sourceID)
    }

    /// Write a track's cache state by id and bump `libraryRevision` so the
    /// revision-keyed `albums` cache recomputes — otherwise the album tile keeps
    /// showing the stale download badge after a download/evict completes. For a
    /// batch that writes many tracks in one synchronous loop, write directly and
    /// bump the revision ONCE afterwards instead of calling this per track.
    private func setCacheState(trackID id: String, _ state: CacheState) {
        guard let i = trackIndex[id], tracks.indices.contains(i) else { return }
        tracks[i].cacheState = state
        libraryRevision &+= 1
    }

    func download(_ id: String) {
        guard let i = trackIndex[id], canManageDownload(id) else { return }
        setCacheState(trackID: id, .downloading)
        let target = tracks[i]
        Task {
            let ok = await library.ensureCached(target)
            setCacheState(trackID: id, ok ? .cached : .failed)
        }
    }

    func removeDownload(_ id: String) {
        guard let i = trackIndex[id], canManageDownload(id) else { return }
        let target = tracks[i]
        Task { await library.evict(target) }
        setCacheState(trackID: id, .remoteOnly)
    }

    func toggleOfflineMode() { offlineMode.toggle() }

    // MARK: Album-level actions (long-press context menu)

    /// Insert the whole album right after the current track, in album order.
    func playAlbumNext(_ albumID: String) {
        let album = playableContext(tracks(forAlbum: albumID))
        guard !album.isEmpty else { return }
        // On an empty queue the first `playNext` auto-starts playback, which with
        // the reversed feed would start on the album's LAST track — just play it
        // in order instead.
        if engine.queue.isEmpty {
            engine.setShuffle(false)
            engine.play(album, startAt: 0)
            return
        }
        // playNext inserts at currentIndex+1, so feed reversed to keep order.
        for track in album.reversed() { engine.playNext(track) }
    }

    /// Append the whole album to the end of the queue, in album order.
    func addAlbumToQueue(_ albumID: String) {
        let album = playableContext(tracks(forAlbum: albumID))
        guard !album.isEmpty else { return }
        for track in album { engine.addToQueue(track) }
    }

    /// A remote album (at least one track can be downloaded/pinned).
    func canManageAlbumDownload(_ albumID: String) -> Bool {
        tracks(forAlbum: albumID).contains { canManageDownload($0.id) }
    }

    /// At least one album track is already on disk (pinned or auto-cached).
    func albumHasDownloads(_ albumID: String) -> Bool {
        tracks(forAlbum: albumID).contains {
            $0.cacheState == .cached || $0.cacheState == .prefetched
        }
    }

    func downloadAlbum(_ albumID: String) {
        let targets = tracks(forAlbum: albumID).filter { canManageDownload($0.id) && $0.cacheState == .remoteOnly }
        guard !targets.isEmpty else { return }
        // Mark all queued, then download sequentially in ONE task — not N
        // fire-and-forget tasks all contending for the source's background client.
        for t in targets where trackIndex[t.id] != nil { tracks[trackIndex[t.id]!].cacheState = .downloading }
        libraryRevision &+= 1   // one rebuild for the whole batch, not per track
        Task { [weak self] in
            guard let self else { return }
            for t in targets {
                let ok = await self.library.ensureCached(t)
                self.setCacheState(trackID: t.id, ok ? .cached : .remoteOnly)
            }
        }
    }

    func removeAlbumDownloads(_ albumID: String) {
        for track in tracks(forAlbum: albumID) where canManageDownload(track.id) {
            removeDownload(track.id)
        }
    }

    /// An album is "favorite" when every track is favorited; toggling sets them all.
    func isAlbumFavorite(_ albumID: String) -> Bool {
        let albumTracks = tracks(forAlbum: albumID)
        return !albumTracks.isEmpty && albumTracks.allSatisfy(\.isFavorite)
    }

    func toggleAlbumFavorite(_ albumID: String) {
        let makeFavorite = !isAlbumFavorite(albumID)
        for track in tracks(forAlbum: albumID) {
            guard let i = trackIndex[track.id] else { continue }
            tracks[i].isFavorite = makeFavorite
            let id = track.id
            Task { await library.setFavorite(makeFavorite, forTrack: id) }
        }
        reconcileAutoCache()
    }

    // MARK: Search

    func searchResults(_ query: String) -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        // Scan the precomputed lowercased haystack (built in rebuildIndex) instead of
        // five locale-aware `contains` per track on every keystroke.
        return tracks.filter { (searchHaystack[$0.id] ?? "").contains(trimmed) }
    }

    // MARK: Wiring

    /// Last track for which a "mostly played → cache whole file" download fired,
    /// so it triggers once per track.
    private var partialCacheTriggeredID: String?

    /// When the user has listened to most of a streamed track, cache the entire
    /// file so it's saved offline — not only when the stream happens to cover 100%
    /// (which never happens if you skip the last bytes).
    private func maybeCacheMostlyPlayed() {
        guard autoCache.isEnabled,
              let track = engine.currentTrack,
              engine.duration > 60,
              engine.elapsed / engine.duration >= 0.75,
              partialCacheTriggeredID != track.id,
              let i = trackIndex[track.id], tracks[i].cacheState == .remoteOnly else { return }
        partialCacheTriggeredID = track.id
        Task { [weak self] in
            guard let self else { return }
            if await self.library.ensureCached(track, auto: true) {
                self.setCacheState(trackID: track.id, .cached)
            }
        }
    }

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
            if let self {
                if let data = await self.library.artworkData(for: track), let image = UIImage(data: data) {
                    return image
                }
                // Streamed track with no local file yet: pull the album cover
                // from the remote source so the lock screen still shows art.
                if let url = await self.library.remoteAlbumArtwork(for: track),
                   let image = UIImage(contentsOfFile: url.path) {
                    return image
                }
            }
            return Artwork.image(for: track.albumID, glyph: track.kind == .video ? "film" : "music.note")
        }
        engine.onDurationResolved = { [weak self] id, seconds in
            guard let self, let i = self.trackIndex[id], self.tracks.indices.contains(i),
                  abs(self.tracks[i].durationSeconds - seconds) > 0.5 else { return }
            self.tracks[i].durationSeconds = seconds
            Task { await self.library.setDuration(seconds, forTrack: id) }
            self.libraryRevision &+= 1
        }
        engine.onPlaybackTick = { [weak self] in
            guard let self else { return }
            self.savePlaybackSnapshot(throttled: true)
            self.maybeCacheMostlyPlayed()
        }
        engine.onTrackStarted = { [weak self] track in
            guard let self else { return }
            // A track that actually started playing proves its source is
            // reachable. Without this, a cold launch (restore + play, no rescan)
            // leaves every source `.asleep`, which silently disables prefetch and
            // auto-cache until the user manually rescans.
            if self.sourceHealth[track.sourceID] != .online {
                self.sourceHealth[track.sourceID] = .online
                self.rebuildSources()
            }
            // Count the play only on a real track change — stall recovery
            // re-fires this for the same track (new generation) and would
            // otherwise double-count it in recents / play counts.
            if self.lastNotedPlayID != track.id {
                self.lastNotedPlayID = track.id
                self.notePlayed(track.id)
            }
            self.prefetchNextIfNeeded()
            Task {
                let cached = await self.library.isCached(track)
                if cached, let i = self.trackIndex[track.id] {
                    switch self.tracks[i].cacheState {
                    case .cached, .prefetched:
                        break
                    case .downloading:
                        self.setCacheState(trackID: track.id, .cached)
                    default:
                        self.setCacheState(trackID: track.id, .prefetched)
                    }
                }
                if let art = await self.library.remoteAlbumArtwork(for: track) {
                    for idx in self.tracks.indices
                    where self.tracks[idx].albumID == track.albumID && self.tracks[idx].artworkURL == nil {
                        self.tracks[idx].artworkURL = art
                    }
                    self.libraryRevision &+= 1
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
                    self.setCacheState(trackID: id, .remoteOnly)
                }
            }
            var downloaded = 0
            var moreToFetch = false
            for id in plan.keep {
                guard let target = self.track(id), target.cacheState == .remoteOnly else { continue }
                // Small bites: each fetch is a full-file download on its own SMB
                // connection competing with the live stream. Fewer per pass (with
                // the reschedule below) keeps background caching from starving
                // playback while still converging on the hot set.
                if downloaded >= 3 { moreToFetch = true; break }
                if await self.library.ensureCached(target, auto: true) {
                    self.setCacheState(trackID: id, .prefetched)
                    downloaded += 1
                }
            }
            self.autoCache.setUsage(await self.library.autoCachedBytes())
            // The hot set can exceed one batch; schedule another pass so the
            // auto-cache actually converges instead of stopping at 8 downloads.
            if moreToFetch { self.reconcileAutoCache() }
        }
    }

    private func notePlayed(_ id: String) {
        recentlyPlayedIDs.removeAll { $0 == id }
        recentlyPlayedIDs.insert(id, at: 0)
        if recentlyPlayedIDs.count > 40 { recentlyPlayedIDs.removeLast() }
        UserDefaults.standard.set(recentlyPlayedIDs, forKey: Self.recentlyPlayedKey)
        savePlaybackSnapshot(throttled: false)   // capture the new current track
        autoCache.recordPlay(id)
        reconcileAutoCache()
    }

    /// Warm the next queued track so advancing/skip starts instantly. Downloads
    /// it into the (evictable) auto-cache when reachable and not a local file
    /// already on disk. Cancels any prior prefetch when the track changes.
    private func prefetchNextIfNeeded() {
        prefetchTask?.cancel()
        guard autoCache.isEnabled, !offlineMode else { return }
        let queue = engine.queue
        guard !queue.isEmpty else { return }
        // Wrap to the head when at the end of a repeat-all queue, so the
        // about-to-play first track is warmed too.
        let raw = engine.currentIndex + 1
        let nextIndex = (raw >= queue.count && engine.repeatMode == .all) ? 0 : raw
        guard queue.indices.contains(nextIndex) else { return }
        let next = queue[nextIndex]
        guard next.kind != .video else { return }   // don't pre-pull large video
        let localIDs = Set(sourceConfigs.filter { $0.proto == SourceProtocol.local.rawValue }.map(\.id))
        guard !localIDs.contains(next.sourceID) else { return }
        guard next.cacheState == .remoteOnly else { return }
        guard sourceHealth[next.sourceID]?.isReachable == true else { return }
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            // Let the live stream establish its initial buffer before pulling the
            // next track in full: both share the one Wi-Fi link to the NAS, and
            // prefetching immediately at track-start is a common cause of
            // mid-playback stalls. A skip within this window cancels the prefetch.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            let ok = await self.library.ensureCached(next, auto: true)
            if Task.isCancelled { return }
            if ok, let i = self.trackIndex[next.id], self.tracks[i].cacheState == .remoteOnly {
                self.setCacheState(trackID: next.id, .prefetched)
            }
        }
    }

    private func reconcileAutoCache() {
        let reachable = sourceHealth.values.contains { $0.isReachable }
        // Local-file tracks are always on-device; never auto-cache/evict them.
        let localIDs = Set(sourceConfigs.filter { $0.proto == SourceProtocol.local.rawValue }.map(\.id))
        let evictable = audioTracks.filter { !localIDs.contains($0.sourceID) }
        autoCache.scheduleReconcile(library: evictable, reachable: reachable && !offlineMode)
        libraryRevision &+= 1   // favorites / cache-state / play-count may have changed
    }

    /// Recompute the auto-cache storage readout from what is actually on disk.
    /// `reconcile` only refreshes this on a successful, reachable pass, so at
    /// launch / offline / right after opening the Offline screen the number was
    /// stale (often 0 despite cached files). The Offline view calls this on
    /// appear so the "X of Y" readout always reflects real on-disk bytes.
    func refreshAutoCacheUsage() {
        Task { [weak self] in
            guard let self else { return }
            self.autoCache.setUsage(await self.library.autoCachedBytes())
        }
    }

    private func isLocalSource(_ sourceID: String) -> Bool {
        sourceConfigs.first(where: { $0.id == sourceID })?.proto == SourceProtocol.local.rawValue
    }
}
