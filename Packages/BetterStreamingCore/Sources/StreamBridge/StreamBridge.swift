import Foundation
import BetterStreamingDomain

public struct StreamURL: Sendable, Equatable {
    public let url: URL
    public let expiresAt: Date

    public init(url: URL, expiresAt: Date) {
        self.url = url
        self.expiresAt = expiresAt
    }
}

public protocol StreamBridging: Sendable {
    func localStreamURL(for itemID: MediaItemID) async throws -> StreamURL
    func stopServing(itemID: MediaItemID) async
}
