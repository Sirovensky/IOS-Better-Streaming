import Foundation
import Testing
import BetterStreamingDomain
import CacheManager
import TestSupport

@Test func cacheRecordStoresCompatibilityState() {
    let record = CacheRecord(id: MediaItemID(), state: .queued)
    #expect(record.state == .queued)
    #expect(record.completedBytes == 0)
}

@Test func cachePathResolverUsesStableRemoteIdentityKey() {
    let sourceID = SourceID(rawValue: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
    let shareID = ShareID(rawValue: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!)
    let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let resolver = CachePathResolver(rootDirectory: URL(fileURLWithPath: "/tmp/cache-root"))

    let first = RemoteItemIdentity(
        sourceID: sourceID,
        shareID: shareID,
        path: RemotePath(displayPath: "/Music/Song.MP3", normalizedPath: "music/song.mp3"),
        remoteFileID: RemoteFileID("file-1"),
        size: 42,
        modifiedAt: modifiedAt
    )
    let second = RemoteItemIdentity(
        sourceID: sourceID,
        shareID: shareID,
        path: RemotePath(displayPath: "\\music\\SONG.mp3", normalizedPath: "music/song.mp3"),
        remoteFileID: RemoteFileID("file-1"),
        size: 42,
        modifiedAt: modifiedAt
    )
    let changed = RemoteItemIdentity(
        sourceID: sourceID,
        shareID: shareID,
        path: RemotePath(displayPath: "/Music/Song.MP3", normalizedPath: "music/song.mp3"),
        remoteFileID: RemoteFileID("file-2"),
        size: 42,
        modifiedAt: modifiedAt
    )

    #expect(resolver.key(for: first) == resolver.key(for: second))
    #expect(resolver.key(for: first) != resolver.key(for: changed))
    #expect(resolver.completeFileURL(for: first).pathExtension == "mp3")
}

@Test func reservationCompletionMovesPartialFileToPlayableCache() async throws {
    let root = temporaryDirectory()
    let manager = FileBackedCacheManager(rootDirectory: root)
    let itemID = MediaItemID()
    let identity = testIdentity(path: "Music/Track.flac", size: 6)

    let reservation = try await manager.reserveCompleteFile(
        for: itemID,
        identity: identity,
        requiredBy: .manual,
        expectedBytes: 6,
        priority: .playback
    )
    try Data("abcdef".utf8).write(to: reservation.temporaryURL)

    let completed = try await manager.completeReservation(reservation.id)
    let localURL = try await manager.localPlayableURL(for: itemID)

    #expect(completed.state == .cached)
    #expect(completed.bytesDone == 6)
    #expect(completed.localFileURL == localURL)
    #expect(FileManager.default.fileExists(atPath: localURL.path))
    #expect(try Data(contentsOf: localURL) == Data("abcdef".utf8))
}

@Test func offlinePlayableAssetNeverRequestsStreamForUncachedItems() async throws {
    let manager = FileBackedCacheManager(rootDirectory: temporaryDirectory())
    let itemID = MediaItemID()

    let onlineAsset = try await manager.playableAsset(for: itemID, offlineMode: false)
    let offlineAsset = try await manager.playableAsset(for: itemID, offlineMode: true)

    #expect(onlineAsset == .requiresStream(itemID))
    #expect(offlineAsset == .unavailable(.notCached))
}

@Test func byteCacheStoresAndReadsExactRange() async throws {
    let manager = FileBackedCacheManager(rootDirectory: temporaryDirectory())
    let itemID = MediaItemID()
    let identity = testIdentity(path: "Music/Track.m4a", size: 100)

    _ = try await manager.reserveCompleteFile(
        for: itemID,
        identity: identity,
        requiredBy: .queuePrefetch(QueueID()),
        expectedBytes: 100,
        priority: .prefetch
    )

    try await manager.storeCachedBytes(for: itemID, range: 10..<16, data: Data("sample".utf8))
    let data = try await manager.readCachedBytes(for: itemID, range: 10..<16)
    let missing = try await manager.readCachedBytes(for: itemID, range: 16..<20)

    #expect(data == Data("sample".utf8))
    #expect(missing == nil)
}

@Test func downloadCompleteFileUsesFakeRemoteWithoutNetwork() async throws {
    let itemID = MediaItemID()
    let path = RemotePath(displayPath: "Music/downloaded.mp3")
    let identity = testIdentity(path: path.displayPath, size: 4)
    let remote = FakeRemoteFileSystem(fileDataByPath: [path: Data("data".utf8)])
    let manager = FileBackedCacheManager(rootDirectory: temporaryDirectory())

    let url = try await manager.downloadCompleteFile(
        for: itemID,
        identity: identity,
        from: remote,
        requiredBy: .manual,
        priority: .playback
    )

    #expect(try Data(contentsOf: url) == Data("data".utf8))
    #expect(try await manager.record(for: itemID)?.state == .cached)
}

@Test func byteProgressCalculatesRemainingAndFraction() {
    let progress = ByteProgress(completedBytes: 25, totalBytes: 100)

    #expect(progress.remainingBytes == 75)
    #expect(progress.fractionCompleted == 0.25)
    #expect(progress.isComplete == false)
}

private func testIdentity(path: String, size: Int64) -> RemoteItemIdentity {
    RemoteItemIdentity(
        sourceID: SourceID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
        shareID: ShareID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
        path: RemotePath(displayPath: path),
        remoteFileID: RemoteFileID(path),
        size: size,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_123)
    )
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("better-streaming-cache-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
