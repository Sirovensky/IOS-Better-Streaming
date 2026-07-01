import Foundation

/// Opt-in online album-art fallback: MusicBrainz release search → Cover Art
/// Archive front image. Off by default. Self-contained and conservative — a
/// proper User-Agent (MusicBrainz requires one) and a ~1.1s minimum spacing
/// between requests to respect the public-API rate limit. Returns image bytes,
/// or nil on any miss/error (the caller falls back to the placeholder glyph).
actor OnlineArtworkClient {
    static let shared = OnlineArtworkClient()

    /// MusicBrainz asks every client to identify itself with a contact.
    private let userAgent = "BetterStreaming/1.0 ( https://github.com/Sirovensky/IOS-Better-Streaming )"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    private var lastRequestAt: Date = .distantPast

    /// Fetch front cover bytes for an artist+album, or nil. Honors the rate limit
    /// by serializing on this actor and spacing requests.
    func frontCover(artist: String, album: String) async -> Data? {
        let artistQ = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumQ = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !albumQ.isEmpty, albumQ.lowercased() != "unknown" else { return nil }
        guard let match = await releaseMatch(artist: artistQ, album: albumQ) else { return nil }
        // Cover art is often attached to the RELEASE-GROUP (or a sibling release),
        // not the exact release MusicBrainz scored highest — so try the specific
        // release first, then fall back to its release-group. (Verified: a release
        // can 404 while its release-group has the cover.)
        if let data = await coverArt(path: "release/\(match.release)") { return data }
        if let group = match.releaseGroup, let data = await coverArt(path: "release-group/\(group)") { return data }
        return nil
    }

    private func releaseMatch(artist: String, album: String) async -> (release: String, releaseGroup: String?)? {
        // Strip Lucene phrase-breakers (a `"` ends the phrase, `\` is the escape
        // char) so an album/artist containing them can't corrupt the query.
        let album = Self.luceneSafe(album)
        let artist = Self.luceneSafe(artist)
        var query = "release:\"\(album)\""
        if !artist.isEmpty, artist.lowercased() != "unknown artist" {
            query += " AND artist:\"\(artist)\""
        }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url, let data = await get(url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = json["releases"] as? [[String: Any]],
              let first = releases.first,
              let id = first["id"] as? String else { return nil }
        let groupID = (first["release-group"] as? [String: Any])?["id"] as? String
        return (id, groupID)
    }

    private func coverArt(path: String) async -> Data? {
        // `front-500` 307-redirects to the actual image; URLSession follows it.
        guard let url = URL(string: "https://coverartarchive.org/\(path)/front-500") else { return nil }
        guard let data = await get(url), data.count > 512, Self.isImageData(data) else { return nil }
        return data
    }

    /// Reject non-image payloads (e.g. an HTML error page that's still >512 bytes)
    /// by checking the magic bytes for JPEG (`FF D8`) or PNG (`89 50 4E 47`).
    private static func isImageData(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(4))
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 { return true }
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return true }
        return false
    }

    private static func luceneSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
    }

    /// GET with the required User-Agent, after waiting out the rate-limit spacing.
    private func get(_ url: URL) async -> Data? {
        // Reserve the next slot SYNCHRONOUSLY (no await between the read and write
        // of `lastRequestAt`) so two callers that interleave on the actor during a
        // sleep each compute a distinct slot instead of racing on a stale stamp —
        // which previously let them hit MusicBrainz simultaneously.
        let slot = max(Date(), lastRequestAt.addingTimeInterval(1.1))
        lastRequestAt = slot
        let delay = slot.timeIntervalSinceNow
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }
}

/// User-selectable online sources for ARTIST photos (MusicBrainz / Cover Art
/// Archive only carries album art). Each toggles independently in Settings; the
/// enabled ones are tried in declaration order until a photo comes back.
enum ArtistImageSource: String, CaseIterable, Identifiable, Sendable {
    case deezer
    case theAudioDB

    var id: String { rawValue }
    var title: String {
        switch self {
        case .deezer: return "Deezer"
        case .theAudioDB: return "TheAudioDB"
        }
    }
    var detail: String {
        switch self {
        case .deezer: return "Broad coverage, high-resolution photos"
        case .theAudioDB: return "Community-contributed artist images"
        }
    }
    var defaultsKey: String { "artistImage.\(rawValue).enabled.v1" }
    var defaultOn: Bool { self == .deezer }

    static func isOn(_ source: ArtistImageSource) -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: source.defaultsKey) == nil ? source.defaultOn : d.bool(forKey: source.defaultsKey)
    }
    /// Currently-enabled sources, in try order.
    static var enabled: [ArtistImageSource] { allCases.filter(isOn) }
}

/// Opt-in online artist-photo fetch across the user's enabled `ArtistImageSource`s.
/// Each is a single keyless JSON lookup that yields a direct image URL, which is
/// then downloaded. Returns image bytes from the first source that has one, or nil.
actor ArtistImageClient {
    static let shared = ArtistImageClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    private var lastRequestAt: Date = .distantPast

    func imageData(forArtist name: String, sources: [ArtistImageSource]) async -> Data? {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = q.lowercased()
        guard !q.isEmpty, lowered != "unknown artist", lowered != "unknown", lowered != "various artists" else { return nil }
        for source in sources {
            if let url = await imageURL(for: q, from: source),
               let data = await download(url), data.count > 512 {
                return data
            }
        }
        return nil
    }

    private func imageURL(for name: String, from source: ArtistImageSource) async -> URL? {
        switch source {
        case .deezer:
            var c = URLComponents(string: "https://api.deezer.com/search/artist")
            c?.queryItems = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "limit", value: "1")]
            guard let url = c?.url, let data = await get(url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["data"] as? [[String: Any]])?.first else { return nil }
            let s = (first["picture_xl"] as? String) ?? (first["picture_big"] as? String)
            // Deezer returns its placeholder URL (…/artist//…) when there's no photo.
            guard let s, !s.isEmpty, !s.contains("/artist//") else { return nil }
            return URL(string: s)
        case .theAudioDB:
            var c = URLComponents(string: "https://www.theaudiodb.com/api/v1/json/2/search.php")
            c?.queryItems = [URLQueryItem(name: "s", value: name)]
            guard let url = c?.url, let data = await get(url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (json["artists"] as? [[String: Any]])?.first,
                  let s = first["strArtistThumb"] as? String, !s.isEmpty else { return nil }
            return URL(string: s)
        }
    }

    /// Rate-limited JSON GET (sources share modest spacing; the image download is
    /// on a different CDN host and not throttled).
    private func get(_ url: URL) async -> Data? {
        // Reserve the next slot synchronously (no await between read and write of
        // `lastRequestAt`) so interleaving callers don't share a stale stamp and
        // fire simultaneously.
        let slot = max(Date(), lastRequestAt.addingTimeInterval(0.5))
        lastRequestAt = slot
        let delay = slot.timeIntervalSinceNow
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
}
