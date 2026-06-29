import Foundation

public enum MediaKind: String, Codable, Sendable {
    case audio
    case video
    case other
    case unknown
    case folder
    case playlist
}

public enum RootMediaKind: String, Codable, Sendable {
    case music
    case video
    case mixed
}

public enum CacheState: String, Codable, Sendable {
    case remoteOnly
    case queued
    case downloading
    case cached
    case prefetched
    case failed
    case stale
    case evicted
}

public enum ScanState: String, Codable, Sendable {
    case unscanned
    case scanning
    case partial
    case complete
    case failed
}

public enum PlaybackRendererKind: String, Codable, Sendable {
    case avPlayer
    case vlcKit
}

public enum PlaybackCapability: Hashable, Codable, Sendable {
    case playable
    case cacheRequired
    case offlineUnavailable
    case sourceUnavailable
    case unsupported(reason: String)
}

public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    public let id: MediaItemID
    public var identity: RemoteItemIdentity
    public var parentFolderID: FolderID?
    public var mediaKind: MediaKind
    public var fileName: String
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval?
    public var artworkURL: URL?
    public var isFavorite: Bool
    public var sortKey: String
    public var playbackCapability: PlaybackCapability?

    public init(
        id: MediaItemID = MediaItemID(),
        identity: RemoteItemIdentity,
        parentFolderID: FolderID? = nil,
        mediaKind: MediaKind,
        fileName: String,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval? = nil,
        artworkURL: URL? = nil,
        isFavorite: Bool = false,
        sortKey: String? = nil,
        playbackCapability: PlaybackCapability? = nil
    ) {
        self.id = id
        self.identity = identity
        self.parentFolderID = parentFolderID
        self.mediaKind = mediaKind
        self.fileName = fileName
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.artworkURL = artworkURL
        self.isFavorite = isFavorite
        self.sortKey = sortKey ?? Self.defaultSortKey(fileName)
        self.playbackCapability = playbackCapability
    }

    private static func defaultSortKey(_ value: String) -> String {
        DefaultRemotePathNormalizer().normalize(value)
    }
}

public struct FolderItem: Identifiable, Hashable, Codable, Sendable {
    public let id: FolderID
    public var identity: RemoteItemIdentity
    public var parentFolderID: FolderID?
    public var name: String
    public var scanState: ScanState
    public var sortKey: String
    public var failureCode: String?

    public init(
        id: FolderID = FolderID(),
        identity: RemoteItemIdentity,
        parentFolderID: FolderID? = nil,
        name: String,
        scanState: ScanState = .unscanned,
        sortKey: String? = nil,
        failureCode: String? = nil
    ) {
        self.id = id
        self.identity = identity
        self.parentFolderID = parentFolderID
        self.name = name
        self.scanState = scanState
        self.sortKey = sortKey ?? Self.defaultSortKey(name)
        self.failureCode = failureCode
    }

    private static func defaultSortKey(_ value: String) -> String {
        DefaultRemotePathNormalizer().normalize(value)
    }
}

public struct FolderChildren: Hashable, Codable, Sendable {
    public var folders: [FolderItem]
    public var mediaItems: [MediaItem]

    public init(folders: [FolderItem] = [], mediaItems: [MediaItem] = []) {
        self.folders = folders
        self.mediaItems = mediaItems
    }
}

public struct LibrarySearchQuery: Hashable, Codable, Sendable {
    public var text: String
    public var sourceID: SourceID?
    public var shareID: ShareID?
    public var mediaKinds: Set<MediaKind>
    public var limit: Int

    public init(
        text: String,
        sourceID: SourceID? = nil,
        shareID: ShareID? = nil,
        mediaKinds: Set<MediaKind> = [],
        limit: Int = 50
    ) {
        self.text = text
        self.sourceID = sourceID
        self.shareID = shareID
        self.mediaKinds = mediaKinds
        self.limit = limit
    }
}

public struct LibrarySearchResult: Hashable, Codable, Sendable {
    public var folders: [FolderItem]
    public var mediaItems: [MediaItem]

    public init(folders: [FolderItem] = [], mediaItems: [MediaItem] = []) {
        self.folders = folders
        self.mediaItems = mediaItems
    }
}

public enum PlaylistKind: String, Codable, Sendable {
    case standard
    case liveFolder
}

public enum PlaylistEntryTarget: Hashable, Codable, Sendable {
    case media(MediaItemID)
    case folder(FolderID, recursive: Bool)
}

public struct PlaylistEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var target: PlaylistEntryTarget
    public var position: Int
    public var title: String?

    public init(
        id: UUID = UUID(),
        target: PlaylistEntryTarget,
        position: Int,
        title: String? = nil
    ) {
        self.id = id
        self.target = target
        self.position = position
        self.title = title
    }
}

public struct Playlist: Identifiable, Hashable, Codable, Sendable {
    public let id: PlaylistID
    public var name: String
    public var kind: PlaylistKind
    public var entries: [PlaylistEntry]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: PlaylistID = PlaylistID(),
        name: String,
        kind: PlaylistKind = .standard,
        entries: [PlaylistEntry] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.entries = entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum QueueRepeatMode: String, Codable, Sendable {
    case off
    case one
    case all
}

public struct QueueEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var mediaItemID: MediaItemID
    public var title: String
    public var subtitle: String?
    public var duration: TimeInterval?

    public init(
        id: UUID = UUID(),
        mediaItemID: MediaItemID,
        title: String,
        subtitle: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.title = title
        self.subtitle = subtitle
        self.duration = duration
    }
}

public struct QueueSnapshot: Identifiable, Hashable, Codable, Sendable {
    public var id: QueueID
    public var items: [QueueEntry]
    public var currentIndex: Int?
    public var isShuffled: Bool
    public var repeatMode: QueueRepeatMode
    public var updatedAt: Date

    public init(
        id: QueueID = QueueID(),
        items: [QueueEntry] = [],
        currentIndex: Int? = nil,
        isShuffled: Bool = false,
        repeatMode: QueueRepeatMode = .off,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.items = items
        self.currentIndex = currentIndex
        self.isShuffled = isShuffled
        self.repeatMode = repeatMode
        self.updatedAt = updatedAt
    }
}

public enum CacheRequiredBy: Hashable, Codable, Sendable {
    case manual
    case folder(FolderID, recursive: Bool)
    case playlist(PlaylistID)
    case smartPack(String)
    case queuePrefetch(QueueID)
}

public struct CacheEntry: Identifiable, Hashable, Codable, Sendable {
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

    public init(
        id: UUID = UUID(),
        mediaItemID: MediaItemID,
        identity: RemoteItemIdentity,
        state: CacheState = .remoteOnly,
        localFileURL: URL? = nil,
        bytesTotal: Int64? = nil,
        bytesDone: Int64 = 0,
        requiredBy: Set<CacheRequiredBy> = [],
        lastPlayedAt: Date? = nil,
        lastVerifiedAt: Date? = nil,
        failureCode: String? = nil
    ) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.identity = identity
        self.state = state
        self.localFileURL = localFileURL
        self.bytesTotal = bytesTotal
        self.bytesDone = bytesDone
        self.requiredBy = requiredBy
        self.lastPlayedAt = lastPlayedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.failureCode = failureCode
    }
}

public struct CacheRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var mediaItemID: MediaItemID
    public var identity: RemoteItemIdentity?
    public var state: CacheState
    public var localFileURL: URL?
    public var bytesTotal: Int64?
    public var bytesDone: Int64
    public var requiredBy: Set<CacheRequiredBy>
    public var lastPlayedAt: Date?
    public var lastVerifiedAt: Date?
    public var failureCode: String?

    public init(
        id: UUID = UUID(),
        mediaItemID: MediaItemID,
        identity: RemoteItemIdentity? = nil,
        state: CacheState,
        localFileURL: URL? = nil,
        bytesTotal: Int64? = nil,
        bytesDone: Int64 = 0,
        requiredBy: Set<CacheRequiredBy> = [],
        lastPlayedAt: Date? = nil,
        lastVerifiedAt: Date? = nil,
        failureCode: String? = nil
    ) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.identity = identity
        self.state = state
        self.localFileURL = localFileURL
        self.bytesTotal = bytesTotal
        self.bytesDone = max(0, bytesDone)
        self.requiredBy = requiredBy
        self.lastPlayedAt = lastPlayedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.failureCode = failureCode
    }

    public init(
        id mediaItemID: MediaItemID,
        localURL: URL? = nil,
        state: CacheState,
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil
    ) {
        self.init(
            mediaItemID: mediaItemID,
            state: state,
            localFileURL: localURL,
            bytesTotal: totalBytes,
            bytesDone: completedBytes
        )
    }
}

public enum ScanMode: String, Codable, Sendable {
    case pathOnly
    case pathAndCheapMetadata
    case rescan
    case repairCandidateSearch
}

public struct ScanRequest: Hashable, Codable, Sendable {
    public var sourceID: SourceID
    public var shareID: ShareID
    public var rootPath: RemotePath
    public var mode: ScanMode

    public init(
        sourceID: SourceID,
        shareID: ShareID,
        rootPath: RemotePath,
        mode: ScanMode = .pathOnly
    ) {
        self.sourceID = sourceID
        self.shareID = shareID
        self.rootPath = rootPath
        self.mode = mode
    }

    public var stableKey: String {
        [
            sourceID.rawValue.uuidString.lowercased(),
            shareID.rawValue.uuidString.lowercased(),
            rootPath.normalizedPath,
            mode.rawValue
        ]
        .map { "\($0.utf8.count):\($0)" }
        .joined()
    }
}

public struct ScanProgress: Hashable, Codable, Sendable {
    public var scanID: ScanID
    public var foldersVisited: Int
    public var filesVisited: Int
    public var mediaItemsFound: Int
    public var currentPath: RemotePath?
    public var isCheckpointed: Bool

    public init(
        scanID: ScanID,
        foldersVisited: Int = 0,
        filesVisited: Int = 0,
        mediaItemsFound: Int = 0,
        currentPath: RemotePath? = nil,
        isCheckpointed: Bool = false
    ) {
        self.scanID = scanID
        self.foldersVisited = foldersVisited
        self.filesVisited = filesVisited
        self.mediaItemsFound = mediaItemsFound
        self.currentPath = currentPath
        self.isCheckpointed = isCheckpointed
    }
}

public struct ScanCheckpoint: Identifiable, Hashable, Codable, Sendable {
    public var id: ScanID
    public var request: ScanRequest
    public var progress: ScanProgress
    public var updatedAt: Date
    public var completedAt: Date?
    public var failureCode: String?

    public init(
        id: ScanID = ScanID(),
        request: ScanRequest,
        progress: ScanProgress? = nil,
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        failureCode: String? = nil
    ) {
        self.id = id
        self.request = request
        self.progress = progress ?? ScanProgress(scanID: id)
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.failureCode = failureCode
    }
}

public struct MediaSummary: Identifiable, Hashable, Sendable {
    public let id: MediaItemID
    public var title: String
    public var subtitle: String?
    public var kind: MediaKind
    public var cacheState: CacheState

    public init(
        id: MediaItemID = MediaItemID(),
        title: String,
        subtitle: String? = nil,
        kind: MediaKind,
        cacheState: CacheState = .remoteOnly
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.cacheState = cacheState
    }
}

public struct FolderSummary: Identifiable, Hashable, Sendable {
    public let id: FolderID
    public var title: String
    public var path: RemotePath
    public var scanState: ScanState
    public var playableCount: Int

    public init(
        id: FolderID = FolderID(),
        title: String,
        path: RemotePath,
        scanState: ScanState = .unscanned,
        playableCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.scanState = scanState
        self.playableCount = playableCount
    }
}
