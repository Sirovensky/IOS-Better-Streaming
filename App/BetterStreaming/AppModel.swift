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
    private var artworkBackfillTask: Task<Void, Never>?
    /// Warms the next queued track so advancing/skip is instant. Cancelled and
    /// replaced whenever the current track changes.
    private var prefetchTask: Task<Void, Never>?

    var hasSources: Bool { !sources.isEmpty }
    var hasLibrary: Bool { !tracks.isEmpty }
    var needsOnboarding: Bool { !isBootstrapping && !hasCompletedOnboarding && sources.isEmpty }

    init() {
        offlineMode = UserDefaults.standard.bool(forKey: "offlineMode.v1")
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "onboarded.v1")
        recentlyPlayedIDs = UserDefaults.standard.stringArray(forKey: Self.recentlyPlayedKey) ?? []
        wireEngine()
        wireAutoCache()
        Task { await bootstrap() }
    }

    // MARK: Persisted playback state

    private static let recentlyPlayedKey = "recentlyPlayed.v1"
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
    private func backfillArtwork() {
        artworkBackfillTask?.cancel()
        guard !offlineMode, !sourceConfigs.isEmpty else { return }
        artworkBackfillTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<12 {
                if Task.isCancelled { return }
                let map = await self.library.backfillAlbumArtwork(for: self.tracks)
                if Task.isCancelled || map.isEmpty { return }
                for i in self.tracks.indices where self.tracks[i].artworkURL == nil {
                    if let url = map[self.tracks[i].albumID] { self.tracks[i].artworkURL = url }
                }
            }
        }
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

    /// App moved to the background: tear down idle background (scan/artwork/
    /// download) connections so the server's session table is freed. The stream
    /// connection is kept so background audio keeps playing; it and any torn-down
    /// background client reconnect lazily on next use.
    func enteredBackground() {
        savePlaybackSnapshot(throttled: false)   // survive an OS-kill while suspended
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
            // Display artist is the album's shared primary artist (or "Various
            // Artists"), not whichever feat.-credited track happens to be first.
            let displayArtist = MetadataGrouping.albumDisplayArtist(from: group.map(\.artist))
            return Album(id: first.albumID, title: first.album, artist: displayArtist, artistID: first.artistID,
                         year: nil, trackCount: group.count, cacheState: anyCached ? .cached : .remoteOnly, artworkURL: artworkURL)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var artists: [Artist] {
        // One entry per individual credited artist. A track credited to several
        // artists (feat./collab) is counted under each, so a featured artist gets
        // their own page listing that song while the album stays under its lead.
        struct Acc { var name: String; var albums: Set<String> = []; var tracks = 0 }
        var byID: [String: Acc] = [:]
        for track in tracks where track.kind == .audio {
            for name in MetadataGrouping.creditedArtists(track.artist) {
                let id = MetadataGrouping.normalizeKey(name)
                guard !id.isEmpty else { continue }
                var acc = byID[id] ?? Acc(name: name)
                acc.albums.insert(track.albumID)
                acc.tracks += 1
                byID[id] = acc
            }
        }
        return byID.map { id, acc in
            Artist(id: id, name: acc.name, albumCount: acc.albums.count, trackCount: acc.tracks, artworkURL: nil)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Display name for an artist id (the first-seen credit spelling).
    func artistName(_ artistID: String) -> String? {
        for track in tracks where track.kind == .audio {
            for name in MetadataGrouping.creditedArtists(track.artist)
            where MetadataGrouping.normalizeKey(name) == artistID {
                return name
            }
        }
        return nil
    }

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

    func tracks(forArtist artistID: String) -> [Track] {
        tracks.filter { $0.kind == .audio && $0.creditedArtistIDs.contains(artistID) }
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
        // The tile shows `seed` as the preview — it must be the FIRST track played.
        // Pin it to the head and let the rest play shuffled (radio feel): with
        // shuffle on, `play(startAt: 0)` keeps index 0 and shuffles only the tail.
        guard list.contains(where: { $0.id == seed.id }) else {
            engine.playShuffled(list)   // seed not playable (offline + uncached)
            return
        }
        let rest = list.filter { $0.id != seed.id }
        engine.setShuffle(true)
        engine.play([seed] + rest, startAt: 0)
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

    // MARK: Album-level actions (long-press context menu)

    /// Insert the whole album right after the current track, in album order.
    func playAlbumNext(_ albumID: String) {
        let album = tracks(forAlbum: albumID)
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
        for track in tracks(forAlbum: albumID) { engine.addToQueue(track) }
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
        for track in tracks(forAlbum: albumID) where canManageDownload(track.id) {
            download(track.id)
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
        }
        engine.onPlaybackTick = { [weak self] in
            self?.savePlaybackSnapshot(throttled: true)
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
            self.notePlayed(track.id)
            self.prefetchNextIfNeeded()
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
                if let art = await self.library.remoteAlbumArtwork(for: track) {
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
            var moreToFetch = false
            for id in plan.keep {
                guard let target = self.track(id), target.cacheState == .remoteOnly else { continue }
                // Small bites: each fetch is a full-file download on its own SMB
                // connection competing with the live stream. Fewer per pass (with
                // the reschedule below) keeps background caching from starving
                // playback while still converging on the hot set.
                if downloaded >= 3 { moreToFetch = true; break }
                if await self.library.ensureCached(target, auto: true) {
                    if let i = self.trackIndex[id] { self.tracks[i].cacheState = .prefetched }
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
        let nextIndex = engine.currentIndex + 1
        guard queue.indices.contains(nextIndex) else { return }
        let next = queue[nextIndex]
        guard next.kind != .video else { return }   // don't pre-pull large video
        let localIDs = Set(sourceConfigs.filter { $0.proto == SourceProtocol.local.rawValue }.map(\.id))
        guard !localIDs.contains(next.sourceID) else { return }
        guard next.cacheState == .remoteOnly else { return }
        guard sourceHealth.values.contains(where: { $0.isReachable }) else { return }
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
                self.tracks[i].cacheState = .prefetched
            }
        }
    }

    private func reconcileAutoCache() {
        let reachable = sourceHealth.values.contains { $0.isReachable }
        // Local-file tracks are always on-device; never auto-cache/evict them.
        let localIDs = Set(sourceConfigs.filter { $0.proto == SourceProtocol.local.rawValue }.map(\.id))
        let evictable = audioTracks.filter { !localIDs.contains($0.sourceID) }
        autoCache.scheduleReconcile(library: evictable, reachable: reachable && !offlineMode)
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
