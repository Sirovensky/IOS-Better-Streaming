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
    case local = "Local"

    var id: String { rawValue }

    /// Server protocols only (excludes on-device local files).
    static var servers: [SourceProtocol] { [.smb, .webDAV, .ftp, .sftp] }

    var isLocal: Bool { self == .local }

    /// Whether Core ships a real adapter for this protocol. SMB, WebDAV and
    /// local files are wired; FTP/SFTP are protocol-neutral behind
    /// RemoteFileSystemClient and need their adapter module built.
    var hasAdapter: Bool { self == .smb || self == .webDAV || self == .ftp || self == .sftp || self == .local }

    /// Whether a live pre-save connection test exists (SMB only today).
    var hasConnectionTest: Bool { self == .smb }

    var subtitle: String {
        switch self {
        case .smb: "Windows / NAS file sharing (most common)"
        case .webDAV: "HTTP-based shares, Nextcloud, many NAS"
        case .ftp: "Classic file servers"
        case .sftp: "FTP over SSH"
        case .local: "Music already on this device or in Files"
        }
    }

    var glyph: String {
        switch self {
        case .smb: "server.rack"
        case .webDAV: "globe"
        case .ftp: "arrow.up.arrow.down.circle"
        case .sftp: "lock.icloud"
        case .local: "iphone"
        }
    }

    var defaultPort: Int {
        switch self {
        case .smb: 445
        case .webDAV: 443
        case .ftp: 21
        case .sftp: 22
        case .local: 0
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

// MARK: - Album / artist grouping
//
// Albums and artists are grouped by *derived* identity keys, not by the raw
// per-track artist tag. Keying an album on `artist::album` shattered any album
// whose tracks credit different artists — "Moonglow" split into one album per
// "Avantasia feat. <singer>", and compilations ("F*** Me I'm Famous!") split
// per DJ. The robust signal for a file library is the folder: one folder is one
// album on a NAS. Artists drop featured-credit noise so a main artist's solo
// and featured tracks land under one artist.

enum MetadataGrouping {
    // Regexes compiled ONCE (these run per-track on hot paths like
    // tracks(forArtist:) / artists / genre grouping; `.regularExpression` on
    // String recompiles every call and caused scroll jank on large libraries).
    private static let bracketRegex = try! NSRegularExpression(pattern: #"[\(\)\[\]]"#)
    private static let whitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)
    /// Separators that mark a real collaboration/feature. Deliberately conservative:
    /// `feat`/`ft`/`featuring`/`vs`/`versus`, plus `&`/`+`. NOT `x`, `with`, or `,`
    /// — those over-match real names ("Tyler, The Creator", "Earth, Wind & Fire"
    /// already only breaks on the `&`; "… with Orchestra"). `&` is kept because the
    /// target library is collaboration-heavy ("David Guetta & Afrojack") — it does
    /// split a few `&`-bands, an accepted trade-off.
    private static let separatorRegex = try! NSRegularExpression(
        pattern: #"\s+(?:feat\.?|ft\.?|featuring|versus|vs\.?)\s+|\s+[&+]\s+"#,
        options: [.caseInsensitive]
    )

    private static func replacingMatches(_ value: String, _ regex: NSRegularExpression, with template: String) -> String {
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }

    /// Split a combined artist credit into the individual artists, in order, so
    /// each one gets their own entry and every track is cross-listed under all of
    /// them. "David Guetta feat. will.i.am & apl.de.ap" -> ["David Guetta",
    /// "will.i.am", "apl.de.ap"]. The first is the main/primary artist.
    static func creditedArtists(_ artist: String) -> [String] {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let separator = "\u{1}"
        let debracketed = replacingMatches(trimmed, bracketRegex, with: " ")
        let flattened = replacingMatches(debracketed, separatorRegex, with: separator)
        var seen = Set<String>()
        var result: [String] = []
        for part in flattened.components(separatedBy: separator) {
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizeKey(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(name)
        }
        return result.isEmpty ? [trimmed] : result
    }

    /// The main artist — the first credited name. Used for album grouping and an
    /// album's display artist so feat./collab tracks group under their lead.
    static func primaryArtist(_ artist: String) -> String {
        creditedArtists(artist).first ?? artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased, whitespace-collapsed key for stable identity comparisons.
    static func normalizeKey(_ value: String) -> String {
        replacingMatches(value, whitespaceRegex, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func isDiscFolder(_ name: String) -> Bool {
        name.range(of: #"^(cd|disc|disk)\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The album folder for a file path, dropping the file name and collapsing a
    /// trailing disc subfolder ("CD1", "Disc 2") so multi-disc sets stay one album.
    static func albumFolderComponents(forPath path: String) -> [String] {
        var comps = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !comps.isEmpty else { return [] }
        comps.removeLast()   // drop the file name -> its parent folder
        if let last = comps.last, isDiscFolder(last) { comps.removeLast() }
        return comps
    }

    /// Stable album identity: album folder + album title. Folder-keyed so feat.-
    /// credited and various-artist albums in one folder stay a single album; the
    /// title keeps two distinct albums in the same folder apart.
    static func albumID(path: String, album: String) -> String {
        let folder = albumFolderComponents(forPath: path).map(normalizeKey).joined(separator: "/")
        let albumKey = normalizeKey(album)
        return folder.isEmpty ? "album::\(albumKey)" : "\(folder)::\(albumKey)"
    }

    static func artistID(_ artist: String) -> String {
        normalizeKey(primaryArtist(artist))
    }

    /// Collapse a noisy genre tag into a broad canonical family so a station
    /// pulls related sub-genres together ("Symphonic Metal", "Heavy Metal",
    /// "Power Metal" -> "Metal"). Returns nil for empty/"Unknown". Unknown tags
    /// are Title-cased and kept as their own family rather than discarded.
    static func canonicalGenre(_ raw: String) -> String? {
        let g = normalizeKey(raw)
        guard !g.isEmpty, g != "unknown", g != "other" else { return nil }
        func has(_ needles: String...) -> Bool { needles.contains { g.contains($0) } }
        if has("metal", "djent", "metalcore", "deathcore", "grindcore") { return "Metal" }
        if has("punk") { return "Punk" }
        if has("hip hop", "hip-hop", "hiphop", "rap", "trap") { return "Hip-Hop" }
        if has("r&b", "rnb", "r & b", "soul", "funk", "motown") { return "R&B / Soul" }
        if has("jazz", "swing", "bebop") { return "Jazz" }
        if has("blues") { return "Blues" }
        if has("classical", "orchestr", "symphon", "baroque", "opera", "concerto", "philharmon") { return "Classical" }
        if has("country", "bluegrass", "americana") { return "Country" }
        if has("reggae", "ska", "dancehall") { return "Reggae" }
        if has("electro", "techno", "house", "trance", "dubstep", "edm", "drum and bass", "dnb", "synth", "ambient", "idm", "breakbeat") { return "Electronic" }
        if has("dance") { return "Dance" }
        if has("folk", "acoustic", "singer-songwriter") { return "Folk" }
        if has("indie") { return "Indie" }
        if has("rock", "grunge", "alternative", "britpop") { return "Rock" }
        if has("pop") { return "Pop" }
        if has("soundtrack", "score", "ost", "cinematic") { return "Soundtrack" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).capitalized
    }

    /// Album display artist from its tracks' artist tags: the shared primary
    /// artist, or "Various Artists" when the primaries genuinely differ.
    static func albumDisplayArtist(from artists: [String]) -> String {
        let primaries = artists.map(primaryArtist).filter { !$0.isEmpty }
        guard let first = primaries.first else { return "Unknown Artist" }
        let distinct = Set(primaries.map(normalizeKey))
        return distinct.count <= 1 ? first : "Various Artists"
    }
}

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
        self.albumID = albumID ?? MetadataGrouping.albumID(path: remotePath ?? folderPath, album: album)
        self.artistID = artistID ?? MetadataGrouping.artistID(artist)
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

    /// Every artist credited on this track (primary + featured + collaborators),
    /// as normalized identity keys, so the track is listed under each of them.
    var creditedArtistIDs: [String] {
        MetadataGrouping.creditedArtists(artist).map(MetadataGrouping.normalizeKey)
    }

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
    /// Total size of the source's media on the server (e.g. "12.3 GB"), or "—".
    var sizeLabel: String = "—"
    /// Base path selected within the share (e.g. "Music"), shown after the share.
    var basePath: String = ""

    var detail: String {
        let trimmed = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let location = trimmed.isEmpty ? share : "\(share)/\(trimmed)"
        return "\(proto.rawValue) · \(host)/\(location)"
    }
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
