import Foundation

/// Opt-in classical-credit enrichment. For one track it asks MusicBrainz for the
/// recording's conductor, performing orchestra, and soloists, follows the linked
/// work to its composer, then normalizes the composer's name + period via OpenOpus.
/// Off by default. Conservative like `OnlineArtworkClient`: the User-Agent
/// MusicBrainz requires, ~1.1s spacing between MB requests (public-API rate limit),
/// and nil on any miss so the caller shows nothing.
actor ClassicalMetadataClient {
    static let shared = ClassicalMetadataClient()

    private let userAgent = "Evensong/1.0 ( https://github.com/Sirovensky/IOS-Better-Streaming )"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    private var lastMusicBrainzRequestAt: Date = .distantPast
    /// A work's composer is shared by every movement, so cache work→composer for the
    /// run to avoid refetching the same work across an album.
    private var workComposerCache: [String: String] = [:]

    /// Resolve credits for one track, or nil if MusicBrainz has no usable match.
    func credits(title: String, artist: String, album: String) async -> ClassicalCredits? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        guard let recordingID = await searchRecordingID(title: title, artist: artist, album: album),
              let recording = await lookupRecording(recordingID) else { return nil }

        var (credits, workID) = Self.credits(fromRecordingRelations: recording.relations ?? [])
        if let workID { credits.composer = await composerName(workID: workID) }
        if let composer = credits.composer, let match = await openOpusComposer(matching: composer) {
            credits.composer = match.completeName
            credits.period = match.epoch
        }
        return credits.isEmpty ? nil : credits
    }

    /// Pure mapping from a recording's relationships to the credit fields it carries.
    /// The composer isn't here — it's a work-level relationship that needs a second
    /// lookup — so this also returns the linked work id to follow. Kept `nonisolated`
    /// + pure so it's unit-testable without a network round-trip.
    nonisolated static func credits(fromRecordingRelations relations: [MBRelation]) -> (credits: ClassicalCredits, workID: String?) {
        var credits = ClassicalCredits()
        var workID: String?
        for relation in relations {
            switch relation.type {
            case "conductor":
                credits.conductor = relation.artist?.name ?? credits.conductor
            case "performing orchestra":
                credits.orchestra = relation.artist?.name ?? credits.orchestra
            // MusicBrainz encodes an instrumental soloist as "instrument" and a
            // singer as "vocal"; bare "performer" is the minority, so mapping only
            // it left soloists nearly always empty.
            case "instrument", "vocal", "performer":
                if let name = relation.artist?.name, !credits.soloists.contains(name) {
                    credits.soloists.append(name)
                }
            case "performance" where relation.targetType == "work":
                credits.work = relation.work?.title ?? credits.work
                workID = relation.work?.id ?? workID
            default:
                break
            }
        }
        return (credits, workID)
    }

    // MARK: MusicBrainz

    private func searchRecordingID(title: String, artist: String, album: String) async -> String? {
        var query = "recording:\"\(Self.luceneSafe(title))\""
        let artist = Self.luceneSafe(artist)
        if !artist.isEmpty, artist.lowercased() != "unknown artist" {
            query += " AND artist:\"\(artist)\""
        }
        let album = Self.luceneSafe(album)
        if !album.isEmpty, album.lowercased() != "unknown" {
            query += " AND release:\"\(album)\""
        }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = components?.url, let data = await getMusicBrainz(url),
              let result = try? JSONDecoder().decode(MBRecordingSearch.self, from: data) else { return nil }
        return result.recordings.first?.id
    }

    private func lookupRecording(_ id: String) async -> MBRecording? {
        guard let url = URL(string: "https://musicbrainz.org/ws/2/recording/\(id)?inc=artist-rels+work-rels&fmt=json"),
              let data = await getMusicBrainz(url) else { return nil }
        return try? JSONDecoder().decode(MBRecording.self, from: data)
    }

    private func composerName(workID: String) async -> String? {
        if let cached = workComposerCache[workID] { return cached }
        guard let url = URL(string: "https://musicbrainz.org/ws/2/work/\(workID)?inc=artist-rels&fmt=json"),
              let data = await getMusicBrainz(url),
              let work = try? JSONDecoder().decode(MBWork.self, from: data) else { return nil }
        let composer = work.relations?.first { $0.type == "composer" }?.artist?.name
        if let composer { workComposerCache[workID] = composer }
        return composer
    }

    // MARK: OpenOpus

    private func openOpusComposer(matching name: String) async -> OpenOpusComposer? {
        // Search by surname (OpenOpus matches it more reliably than a full "First Last").
        let surname = name.split(separator: " ").last.map(String.init) ?? name
        guard let encoded = surname.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.openopus.org/composer/list/search/\(encoded).json"),
              let data = await get(url),   // OpenOpus has no MB-style rate limit
              let composers = (try? JSONDecoder().decode(OpenOpusComposerSearch.self, from: data))?.composers,
              !composers.isEmpty else { return nil }
        // An exact full-name match is unambiguously the same person. Otherwise only
        // trust a single surname result — a shared-surname family (Bach, Strauss, Haydn)
        // with no exact match is ambiguous, so don't guess (the caller keeps the
        // authoritative MusicBrainz composer name instead of a wrong OpenOpus one).
        if let exact = composers.first(where: { $0.completeName.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        return composers.count == 1 ? composers.first : nil
    }

    // MARK: Networking

    /// GET honoring the MusicBrainz rate limit — serialized on this actor, the next
    /// slot reserved synchronously (no await between read and write of the stamp) so
    /// interleaving callers space out instead of racing on a stale timestamp.
    private func getMusicBrainz(_ url: URL) async -> Data? {
        let slot = max(Date(), lastMusicBrainzRequestAt.addingTimeInterval(1.1))
        lastMusicBrainzRequestAt = slot
        let delay = slot.timeIntervalSinceNow
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        return await get(url)
    }

    private func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private static func luceneSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
    }
}

// MARK: - Wire formats

/// Decodable slices of the MusicBrainz ws/2 + OpenOpus JSON — only the fields the
/// enrichment reads.
struct MBRecordingSearch: Decodable { let recordings: [MBRecordingRef] }
struct MBRecordingRef: Decodable { let id: String }

struct MBRecording: Decodable { let relations: [MBRelation]? }
struct MBWork: Decodable { let relations: [MBRelation]? }

struct MBRelation: Decodable {
    let type: String
    let targetType: String?
    let artist: MBArtistRef?
    let work: MBWorkRef?
    enum CodingKeys: String, CodingKey {
        case type, artist, work
        case targetType = "target-type"
    }
}
struct MBArtistRef: Decodable { let id: String; let name: String; let type: String? }
struct MBWorkRef: Decodable { let id: String; let title: String }

struct OpenOpusComposerSearch: Decodable { let composers: [OpenOpusComposer]? }
struct OpenOpusComposer: Decodable {
    let name: String
    let completeName: String
    let epoch: String?
    enum CodingKeys: String, CodingKey {
        case name
        case completeName = "complete_name"
        case epoch
    }
}
