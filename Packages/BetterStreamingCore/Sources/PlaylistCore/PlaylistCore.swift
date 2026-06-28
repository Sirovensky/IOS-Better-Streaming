import Foundation
import BetterStreamingDomain

public enum PlaylistMember: Hashable, Codable, Sendable {
    case media(MediaItemID)
    case folder(FolderID, recursive: Bool)
}

public struct PlaylistSummary: Identifiable, Hashable, Codable, Sendable {
    public let id: PlaylistID
    public var name: String
    public var members: [PlaylistMember]

    public init(id: PlaylistID = PlaylistID(), name: String, members: [PlaylistMember] = []) {
        self.id = id
        self.name = name
        self.members = members
    }
}
