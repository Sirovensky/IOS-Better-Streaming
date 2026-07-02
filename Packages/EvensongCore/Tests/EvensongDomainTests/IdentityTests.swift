import Foundation
import Testing
@testable import EvensongDomain

@Test func remotePathNormalizesSeparatorsAndCase() {
    let path = RemotePath(displayPath: "\\Music\\Albums\\Track.FLAC")
    #expect(path.normalizedPath == "music/albums/track.flac")
}

@Test func remotePathEqualityUsesNormalizedPath() {
    let first = RemotePath(displayPath: "Music/Albums/Track.flac")
    let second = RemotePath(displayPath: "\\music\\albums\\TRACK.FLAC")

    #expect(first == second)
    #expect(Set([first, second]).count == 1)
}

@Test func remoteIdentityStableKeyIncludesFileMetadata() {
    let sourceID = SourceID()
    let shareID = ShareID()
    let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)

    let first = RemoteItemIdentity(
        sourceID: sourceID,
        shareID: shareID,
        path: RemotePath(displayPath: "Music/song.mp3"),
        remoteFileID: RemoteFileID("inode-1"),
        size: 42,
        modifiedAt: modifiedAt
    )
    let sameNormalizedPath = RemoteItemIdentity(
        sourceID: sourceID,
        shareID: shareID,
        path: RemotePath(displayPath: "\\music\\SONG.mp3"),
        remoteFileID: RemoteFileID("inode-1"),
        size: 42,
        modifiedAt: modifiedAt
    )
    let changedFile = RemoteItemIdentity(
        sourceID: sourceID,
        shareID: shareID,
        path: RemotePath(displayPath: "Music/song.mp3"),
        remoteFileID: RemoteFileID("inode-2"),
        size: 42,
        modifiedAt: modifiedAt
    )

    #expect(first.stableKey == sameNormalizedPath.stableKey)
    #expect(first.stableKey != changedFile.stableKey)
}

@Test func queueCacheAndScanModelsAreCodable() throws {
    let sourceID = SourceID()
    let shareID = ShareID()
    let mediaID = MediaItemID()
    let identity = RemoteItemIdentity(
        sourceID: sourceID,
        shareID: shareID,
        path: RemotePath(displayPath: "Music/song.mp3"),
        size: 10,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let payload = CacheEntry(
        mediaItemID: mediaID,
        identity: identity,
        state: .cached,
        requiredBy: [.manual, .queuePrefetch(QueueID())]
    )

    let encoded = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(CacheEntry.self, from: encoded)

    #expect(decoded.mediaItemID == mediaID)
    #expect(decoded.identity.stableKey == identity.stableKey)
    #expect(decoded.state == CacheState.cached)
}
