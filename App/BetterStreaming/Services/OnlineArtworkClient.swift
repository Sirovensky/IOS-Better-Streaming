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
        guard let mbid = await releaseMBID(artist: artistQ, album: albumQ) else { return nil }
        return await coverArt(forReleaseMBID: mbid)
    }

    private func releaseMBID(artist: String, album: String) async -> String? {
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
        return id
    }

    private func coverArt(forReleaseMBID mbid: String) async -> Data? {
        // `front-500` 302-redirects to the actual image; URLSession follows it.
        guard let url = URL(string: "https://coverartarchive.org/release/\(mbid)/front-500") else { return nil }
        guard let data = await get(url), data.count > 512 else { return nil }
        return data
    }

    /// GET with the required User-Agent, after waiting out the rate-limit spacing.
    private func get(_ url: URL) async -> Data? {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < 1.1 {
            try? await Task.sleep(nanoseconds: UInt64((1.1 - elapsed) * 1_000_000_000))
        }
        lastRequestAt = Date()
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
