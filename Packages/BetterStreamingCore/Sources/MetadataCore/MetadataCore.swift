import Foundation
import BetterStreamingDomain

public struct MediaMetadata: Hashable, Codable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var duration: TimeInterval?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

public protocol MetadataReading: Sendable {
    func metadata(for itemID: MediaItemID, localURL: URL) async throws -> MediaMetadata
}
