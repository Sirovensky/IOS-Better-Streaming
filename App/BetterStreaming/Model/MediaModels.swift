import Foundation

// MARK: - Media kind

enum MediaKind: String, Codable, Sendable, Hashable {
    case audio
    case video
}

// MARK: - Cache / availability state
//
// Mirrors `MediaAvailability` from docs/internal-contracts.md. The UI must never
// communicate this by colour alone, so every case carries a label and a glyph.

enum CacheState: String, Codable, Sendable, Hashable, CaseIterable {
    case remoteOnly
    case queued
    case downloading
    case prefetched
    case cached
    case stale
    case missingSource
    case failed

    /// Whether the item can begin playback while Offline Mode is on.
    var isPlayableOffline: Bool {
        switch self {
        case .cached, .prefetched, .stale: true
        case .remoteOnly, .queued, .downloading, .missingSource, .failed: false
        }
    }

    var label: String {
        switch self {
        case .remoteOnly: "Streaming"
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .prefetched: "Ready"
        case .cached: "Downloaded"
        case .stale: "Needs refresh"
        case .missingSource: "Source offline"
        case .failed: "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .remoteOnly: "dot.radiowaves.up.forward"
        case .queued: "clock"
        case .downloading: "arrow.down.circle"
        case .prefetched: "bolt.fill"
        case .cached: "arrow.down.circle.fill"
        case .stale: "exclamationmark.arrow.triangle.2.circlepath"
        case .missingSource: "externaldrive.badge.xmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Source health

enum SourceHealth: String, Codable, Sendable, Hashable {
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

    var isReachable: Bool { self == .online || self == .degraded }
}

enum SourceProtocol: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case smb = "SMB"
    case webDAV = "WebDAV"
    case ftp = "FTP"
    case sftp = "SFTP"

    var id: String { rawValue }

    /// Whether Core ships a real adapter for this protocol. SMB and WebDAV are
    /// wired; FTP/SFTP are protocol-neutral behind RemoteFileSystemClient and
    /// need their adapter module built (see build checklist).
    var hasAdapter: Bool { self == .smb || self == .webDAV }

    /// Whether a live pre-save connection test exists (SMB only today).
    var hasConnectionTest: Bool { self == .smb }

    var subtitle: String {
        switch self {
        case .smb: "Windows / NAS file sharing (most common)"
        case .webDAV: "HTTP-based shares, Nextcloud, many NAS"
        case .ftp: "Classic file servers"
        case .sftp: "FTP over SSH"
        }
    }

    var glyph: String {
        switch self {
        case .smb: "server.rack"
        case .webDAV: "globe"
        case .ftp: "arrow.up.arrow.down.circle"
        case .sftp: "lock.icloud"
        }
    }

    var defaultPort: Int {
        switch self {
        case .smb: 445
        case .webDAV: 443
        case .ftp: 21
        case .sftp: 22
        }
    }

    /// "Share" for SMB, "Path" for the rest.
    var pathFieldLabel: String { self == .smb ? "Share" : "Base path" }
}

// MARK: - Core media models
//
// These are presentation-facing models for the app target. They map from the
// `MediaStore` domain models (BetterStreamingDomain) at the service boundary;
// identity here is a stable opaque string derived from RemoteItemIdentity, never
// a raw smb:// URL.

struct Track: Identifiable, Hashable, Sendable, Codable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var albumID: String
    var artistID: String
    var genre: String
    var durationSeconds: Double
    var trackNumber: Int?
    var discNumber: Int?
    var kind: MediaKind
    var cacheState: CacheState
    var isFavorite: Bool
    var sourceID: String
    var sourceName: String
    /// Middle-truncatable display path within the share. Never a credential URL.
    var folderPath: String
    /// Resolved artwork (local cached file or remote). May be nil → placeholder.
    var artworkURL: URL?
    /// Directly playable URL when known up front (rare). Normally nil — the
    /// resolver returns a local cache file or loopback stream URL at play time.
    var assetURL: URL?
    // Remote identity fields, used to rebuild a RemoteItemIdentity for download.
    var shareID: String?
    var remotePath: String?
    var sizeBytes: Int64?
    var modifiedAtEpoch: Double?

    init(
        id: String,
        title: String,
        artist: String,
        album: String,
        albumID: String? = nil,
        artistID: String? = nil,
        genre: String = "Unknown",
        durationSeconds: Double,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        kind: MediaKind = .audio,
        cacheState: CacheState = .remoteOnly,
        isFavorite: Bool = false,
        sourceID: String,
        sourceName: String,
        folderPath: String,
        artworkURL: URL? = nil,
        assetURL: URL? = nil,
        shareID: String? = nil,
        remotePath: String? = nil,
        sizeBytes: Int64? = nil,
        modifiedAtEpoch: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumID = albumID ?? "\(artist)::\(album)".lowercased()
        self.artistID = artistID ?? artist.lowercased()
        self.genre = genre
        self.durationSeconds = durationSeconds
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.kind = kind
        self.cacheState = cacheState
        self.isFavorite = isFavorite
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.folderPath = folderPath
        self.artworkURL = artworkURL
        self.assetURL = assetURL
        self.shareID = shareID
        self.remotePath = remotePath
        self.sizeBytes = sizeBytes
        self.modifiedAtEpoch = modifiedAtEpoch
    }

    var durationLabel: String { TimeFormat.clock(durationSeconds) }

    var fileExtension: String { (folderPath as NSString).pathExtension.lowercased() }

    var isLossless: Bool { ["flac", "wav", "aiff", "aif", "alac"].contains(fileExtension) }

    /// Short codec/quality label for the player (mirrors Apple Music's format chip).
    var formatLabel: String {
        switch fileExtension {
        case "flac": "FLAC · Lossless"
        case "wav", "aiff", "aif": "Lossless"
        case "alac", "m4a": "ALAC / AAC"
        case "mp3": "MP3"
        case "aac": "AAC"
        case "opus", "ogg": "Compatibility"
        case "": ""
        default: fileExtension.uppercased()
        }
    }
}

struct Album: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var artist: String
    var artistID: String
    var year: Int?
    var trackCount: Int
    var cacheState: CacheState
    var artworkURL: URL?
}

struct Artist: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var albumCount: Int
    var trackCount: Int
    var artworkURL: URL?
}

struct Playlist: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var subtitle: String
    var trackIDs: [String]
    var artworkURLs: [URL]
    var isLiveFolder: Bool

    var trackCount: Int { trackIDs.count }
}

struct LibrarySource: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var proto: SourceProtocol
    var host: String
    var share: String
    var health: SourceHealth
    var trackCount: Int
    var folderCount: Int
    var lastScanLabel: String
    var speedLabel: String

    var detail: String { "\(proto.rawValue) · \(host)/\(share)" }
}

// MARK: - Time formatting

enum TimeFormat {
    /// "3:07" / "1:02:33". Negative values render with a leading minus.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let negative = seconds < 0
        let total = Int(abs(seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let body: String
        if h > 0 {
            body = String(format: "%d:%02d:%02d", h, m, s)
        } else {
            body = String(format: "%d:%02d", m, s)
        }
        return negative ? "-\(body)" : body
    }
}

// MARK: - String path helpers

extension String {
    /// Middle-truncate long NAS paths instead of dropping the meaningful tail.
    func middleTruncated(maxLength: Int) -> String {
        guard count > maxLength, maxLength > 8 else { return self }
        let sideCount = (maxLength - 3) / 2
        let start = prefix(sideCount)
        let end = suffix(maxLength - sideCount - 3)
        return "\(start)...\(end)"
    }
}
