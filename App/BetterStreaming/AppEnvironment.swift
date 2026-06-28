import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    private let persistence: AppPersistence

    @Published var sources: [LibrarySource] {
        didSet { persistence.saveSources(sources) }
    }
    @Published var folders: [LibraryFolder] = []
    @Published var tracks: [MediaTrack] = []
    @Published var albums: [MediaAlbum] = []
    @Published var artists: [MediaArtist] = []
    @Published var downloads: [DownloadPack] = []
    @Published var queue: [QueueEntry] = []
    @Published var genres: [MediaGenre] = []
    @Published var miniPlayer = MiniPlayerState.placeholder
    @Published var nowPlaying = NowPlayingState.placeholder
    @Published var offlineMode: Bool {
        didSet { persistence.saveOfflineMode(offlineMode) }
    }

    init(persistence: AppPersistence = .live) {
        self.persistence = persistence
        self.sources = persistence.loadSources()
        self.offlineMode = persistence.loadOfflineMode()
    }

    var librarySummary: LibrarySummary {
        LibrarySummary(
            sourceCount: sources.count,
            folderCount: folders.count,
            trackCount: tracks.filter { $0.kind == .audio }.count,
            videoCount: tracks.filter { $0.kind == .video }.count
        )
    }

    var playableOfflineCount: Int {
        tracks.filter { $0.cacheStatus == .cached || $0.cacheStatus == .prefetched || $0.cacheStatus == .stale }.count
    }

    var activeDownloadCount: Int {
        downloads.filter { $0.status == .downloading || $0.status == .queued }.count
    }

    var hasActivePlayback: Bool {
        nowPlaying != .placeholder || !queue.isEmpty
    }

    func play(_ track: MediaTrack) {
        guard track.isPlayable(offlineMode: offlineMode) else {
            miniPlayer = MiniPlayerState(
                title: track.title,
                subtitle: "Not cached for Offline Mode",
                isPlaying: false,
                progress: 0,
                statusLabel: "Not cached",
                status: .missingSource,
                artworkSymbol: track.kind == .video ? "film" : "music.note"
            )
            nowPlaying = NowPlayingState(
                title: track.title,
                artist: track.artist,
                album: track.album,
                sourceName: track.sourceName,
                cacheLabel: "Not cached",
                duration: track.duration,
                elapsed: "0:00",
                isPlaying: false,
                status: .missingSource,
                artworkSymbol: track.kind == .video ? "film" : "music.note"
            )
            return
        }

        miniPlayer = MiniPlayerState(
            title: track.title,
            subtitle: "\(track.artist) - \(track.sourceName)",
            isPlaying: true,
            progress: 0.36,
            statusLabel: track.cacheStatus.playerLabel,
            status: track.cacheStatus,
            artworkSymbol: track.kind == .video ? "film" : "music.note"
        )
        nowPlaying = NowPlayingState(
            title: track.title,
            artist: track.artist,
            album: track.album,
            sourceName: track.sourceName,
            cacheLabel: track.cacheStatus.playerLabel,
            duration: track.duration,
            elapsed: track.sampleElapsed,
            isPlaying: true,
            status: track.cacheStatus,
            artworkSymbol: track.kind == .video ? "film" : "music.note"
        )

        if !queue.contains(where: { $0.trackID == track.id }) {
            queue.insert(
                QueueEntry(
                    trackID: track.id,
                    title: track.title,
                    subtitle: "\(track.artist) - \(track.album)",
                    duration: track.duration
                ),
                at: min(1, queue.count)
            )
        }
    }

    func playFolder(_ folder: LibraryFolder, recursive: Bool, shuffled: Bool) {
        let folderTracks = tracks.filter { track in
            track.folderPath.contains(folder.name) || track.sourceName == folder.sourceName
        }.filter { $0.isPlayable(offlineMode: offlineMode) }
        let selected = shuffled ? folderTracks.shuffled() : folderTracks

        guard let first = selected.first else { return }
        play(first)
        queue = selected.prefix(8).map {
            QueueEntry(
                trackID: $0.id,
                title: $0.title,
                subtitle: recursive ? "Recursive - \($0.folderPath)" : "\($0.artist) - \($0.album)",
                duration: $0.duration
            )
        }
    }

    func togglePlayback() {
        miniPlayer.isPlaying.toggle()
        nowPlaying.isPlaying = miniPlayer.isPlaying
    }

    func skipForward() {
        guard let next = queue.dropFirst().first,
              let track = tracks.first(where: { $0.id == next.trackID })
        else { return }

        queue.removeFirst()
        play(track)
    }

    func toggleOfflineMode() {
        offlineMode.toggle()
    }

    func searchResults(for query: String) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }

        let matches = tracks.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.artist.localizedCaseInsensitiveContains(trimmed)
                || $0.album.localizedCaseInsensitiveContains(trimmed)
                || $0.genre.localizedCaseInsensitiveContains(trimmed)
                || $0.folderPath.localizedCaseInsensitiveContains(trimmed)
        }.map {
            SearchResult(
                title: $0.title,
                subtitle: "\($0.artist) - \($0.album) - \($0.genre)",
                context: $0.folderPath,
                systemImage: $0.kind == .video ? "film" : "music.note",
                status: $0.cacheStatus
            )
        }

        let folderMatches = folders.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.path.localizedCaseInsensitiveContains(trimmed)
        }.map {
            SearchResult(
                title: $0.name,
                subtitle: "\($0.sourceName) - \($0.childSummary)",
                context: $0.path,
                systemImage: "folder",
                status: $0.cacheStatus
            )
        }

        return matches + folderMatches
    }

    func addSMBSource(host: String, share: String, username: String, rootPath: String, isOnline: Bool) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootDisplayPath = trimmedRoot.isEmpty ? "/" : trimmedRoot
        let rootName = trimmedRoot.isEmpty ? trimmedShare : trimmedRoot
        sources.append(
            LibrarySource(
                name: trimmedShare,
                detail: "SMB - \(trimmedHost)/\(trimmedShare)",
                health: isOnline ? .online : .unreachable,
                lastScan: "Not scanned",
                speed: "Not sampled",
                recommendation: isOnline ? "Connected" : "Needs test",
                indexedItems: "0 tracks - 0 folders",
                roots: [
                    SourceRootSummary(name: rootName, path: rootDisplayPath, kind: "Music")
                ]
            )
        )
    }

    func removeSource(_ source: LibrarySource) {
        sources.removeAll { $0.id == source.id }
        if sources.isEmpty {
            folders = []
            tracks = []
            albums = []
            artists = []
            downloads = []
            queue = []
            genres = []
            miniPlayer = .placeholder
            nowPlaying = .placeholder
        }
    }

    func autoplayCandidates(seed: MediaTrack?) -> [MediaTrack] {
        let audioTracks = tracks
            .filter { $0.kind == .audio }
            .filter { $0.isPlayable(offlineMode: offlineMode) }

        guard let seed else {
            return audioTracks
        }

        return audioTracks
            .filter { $0.id != seed.id }
            .sorted { lhs, rhs in
                autoplayScore(lhs, seed: seed) > autoplayScore(rhs, seed: seed)
            }
    }

    private func autoplayScore(_ candidate: MediaTrack, seed: MediaTrack) -> Int {
        var score = 0
        if candidate.genre == seed.genre { score += 5 }
        if candidate.artist == seed.artist { score += 3 }
        if candidate.album == seed.album { score += 2 }
        if candidate.cacheStatus == .cached || candidate.cacheStatus == .prefetched { score += 1 }
        return score
    }
}

struct LibrarySummary {
    var sourceCount: Int
    var folderCount: Int
    var trackCount: Int
    var videoCount: Int

    static let placeholder = LibrarySummary(sourceCount: 0, folderCount: 0, trackCount: 0, videoCount: 0)
}

struct AppPersistence {
    @MainActor static let live = AppPersistence(defaults: .standard)

    private let defaults: UserDefaults
    private let sourcesKey = "better-streaming.sources.v1"
    private let offlineModeKey = "better-streaming.offline-mode.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func loadSources() -> [LibrarySource] {
        guard let data = defaults.data(forKey: sourcesKey),
              let stored = try? JSONDecoder().decode([StoredLibrarySource].self, from: data)
        else {
            return []
        }
        return stored.map(\.librarySource)
    }

    func saveSources(_ sources: [LibrarySource]) {
        let stored = sources.map(StoredLibrarySource.init(source:))
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: sourcesKey)
    }

    func loadOfflineMode() -> Bool {
        defaults.bool(forKey: offlineModeKey)
    }

    func saveOfflineMode(_ offlineMode: Bool) {
        defaults.set(offlineMode, forKey: offlineModeKey)
    }
}

private struct StoredLibrarySource: Codable {
    var id: UUID
    var name: String
    var detail: String
    var health: SourceHealth
    var lastScan: String
    var speed: String
    var recommendation: String
    var indexedItems: String
    var roots: [StoredSourceRoot]

    init(source: LibrarySource) {
        id = source.id
        name = source.name
        detail = source.detail
        health = source.health
        lastScan = source.lastScan
        speed = source.speed
        recommendation = source.recommendation
        indexedItems = source.indexedItems
        roots = source.roots.map(StoredSourceRoot.init(root:))
    }

    var librarySource: LibrarySource {
        LibrarySource(
            id: id,
            name: name,
            detail: detail,
            health: health,
            lastScan: lastScan,
            speed: speed,
            recommendation: recommendation,
            indexedItems: indexedItems,
            roots: roots.map(\.sourceRoot)
        )
    }
}

private struct StoredSourceRoot: Codable {
    var id: UUID
    var name: String
    var path: String
    var kind: String

    init(root: SourceRootSummary) {
        id = root.id
        name = root.name
        path = root.path
        kind = root.kind
    }

    var sourceRoot: SourceRootSummary {
        SourceRootSummary(id: id, name: name, path: path, kind: kind)
    }
}

enum LibraryMode: String, CaseIterable, Identifiable {
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
    case genres = "Genres"
    case folders = "Folders"
    case videos = "Videos"

    var id: String { rawValue }
}

enum MediaKind: String, Sendable {
    case audio
    case video
}

enum CacheStatus: String, Sendable {
    case cached
    case downloading
    case queued
    case prefetched
    case stale
    case remoteOnly
    case missingSource
    case failed

    var label: String {
        switch self {
        case .cached: "Cached"
        case .downloading: "Downloading"
        case .queued: "Queued"
        case .prefetched: "Prefetched"
        case .stale: "Stale"
        case .remoteOnly: "Remote"
        case .missingSource: "Missing"
        case .failed: "Failed"
        }
    }

    var playerLabel: String {
        switch self {
        case .cached: "Cached"
        case .downloading: "Caching"
        case .queued: "Queued"
        case .prefetched: "Prefetched"
        case .stale: "Cached, stale"
        case .remoteOnly: "Streaming"
        case .missingSource: "Source offline"
        case .failed: "Retry needed"
        }
    }

    var systemImage: String {
        switch self {
        case .cached: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle"
        case .queued: "clock.arrow.circlepath"
        case .prefetched: "bolt.fill"
        case .stale: "exclamationmark.triangle"
        case .remoteOnly: "externaldrive"
        case .missingSource: "externaldrive.badge.xmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

enum SourceHealth: String, Codable, Sendable {
    case online = "Online"
    case degraded = "Slow"
    case asleep = "Asleep"
    case authFailed = "Auth failed"
    case localNetworkBlocked = "Local Network blocked"
    case unreachable = "Unreachable"

    var systemImage: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .degraded: "wifi.exclamationmark"
        case .asleep: "moon"
        case .authFailed: "lock.trianglebadge.exclamationmark"
        case .localNetworkBlocked: "network.badge.shield.half.filled"
        case .unreachable: "wifi.slash"
        }
    }
}

struct LibrarySource: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var detail: String
    var health: SourceHealth
    var lastScan: String
    var speed: String
    var recommendation: String
    var indexedItems: String
    var roots: [SourceRootSummary]
}

struct SourceRootSummary: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var path: String
    var kind: String
}

struct MediaTrack: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    var artist: String
    var album: String
    var genre: String = "Unknown"
    var sourceName: String
    var folderPath: String
    var duration: String
    var bitrate: String
    var kind: MediaKind
    var cacheStatus: CacheStatus
    var isFavorite: Bool = false

    var sampleElapsed: String {
        switch duration {
        case "5:42": "2:04"
        case "4:18": "1:11"
        case "6:08": "3:36"
        default: "0:48"
        }
    }

    func isPlayable(offlineMode: Bool) -> Bool {
        guard offlineMode else { return true }
        return cacheStatus == .cached || cacheStatus == .prefetched || cacheStatus == .stale
    }
}

struct MediaAlbum: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    var artist: String
    var trackCount: Int
    var cacheStatus: CacheStatus
    var symbol: String
}

struct MediaArtist: Identifiable, Hashable, Sendable {
    let id = UUID()
    var name: String
    var detail: String
    var topPath: String
    var cacheStatus: CacheStatus
}

struct MediaGenre: Identifiable, Hashable, Sendable {
    let id = UUID()
    var name: String
    var detail: String
    var trackCount: Int
    var cacheStatus: CacheStatus
}

struct LibraryFolder: Identifiable, Hashable, Sendable {
    let id = UUID()
    var name: String
    var path: String
    var sourceName: String
    var scanState: String
    var childSummary: String
    var recursiveCount: String
    var cacheStatus: CacheStatus
    var isPlayable: Bool
    var isScanning: Bool
}

struct DownloadPack: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    var reason: String
    var status: CacheStatus
    var detail: String
    var progress: Double
    var bytes: String
}

struct QueueEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    var trackID: UUID
    var title: String
    var subtitle: String
    var duration: String
}

struct MiniPlayerState: Hashable, Sendable {
    var title: String
    var subtitle: String
    var isPlaying: Bool
    var progress: Double
    var statusLabel: String
    var status: CacheStatus
    var artworkSymbol: String

    static let placeholder = MiniPlayerState(
        title: "No media playing",
        subtitle: "Add an SMB source to start",
        isPlaying: false,
        progress: 0,
        statusLabel: "Idle",
        status: .remoteOnly,
        artworkSymbol: "music.note"
    )
}

struct NowPlayingState: Hashable, Sendable {
    var title: String
    var artist: String
    var album: String
    var sourceName: String
    var cacheLabel: String
    var duration: String
    var elapsed: String
    var isPlaying: Bool
    var status: CacheStatus
    var artworkSymbol: String

    static let placeholder = NowPlayingState(
        title: "No media playing",
        artist: "Add a source",
        album: "Library is empty",
        sourceName: "No source",
        cacheLabel: "Idle",
        duration: "0:00",
        elapsed: "0:00",
        isPlaying: false,
        status: .remoteOnly,
        artworkSymbol: "music.note"
    )
}

struct SearchResult: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    var subtitle: String
    var context: String
    var systemImage: String
    var status: CacheStatus
}
