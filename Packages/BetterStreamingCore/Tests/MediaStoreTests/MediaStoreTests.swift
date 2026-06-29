import Foundation
import Testing
import MediaStore

@Test func mediaStoreCanMigrateDatabase() async throws {
    let store = MediaStore(configuration: .inMemory())
    try await store.migrateIfNeeded()
}

@Test func mediaStorePersistsSourcesFoldersMediaAndSearch() async throws {
    let store = MediaStore(configuration: .inMemory())
    let sourceID = SourceID()
    let shareID = ShareID()
    let source = SourceRecord(
        id: sourceID,
        displayName: "NAS",
        protocolKind: .smb,
        endpoint: SourceEndpoint(hostDisplayName: "nas.local", shareName: "Media"),
        roots: [
            SourceRoot(
                id: shareID,
                path: RemotePath(displayPath: "Music"),
                mediaKind: .music,
                displayName: "Music"
            )
        ],
        createdAt: testDate(0),
        updatedAt: testDate(1)
    )

    try await store.upsertSource(source)
    #expect(try await store.source(id: sourceID)?.displayName == "NAS")
    #expect(try await store.listSources().count == 1)

    let folderIdentity = identity(sourceID: sourceID, shareID: shareID, path: "Music/Albums")
    let firstFolder = try await store.upsertFolder(
        FolderItem(
            id: FolderID(),
            identity: folderIdentity,
            name: "Albums",
            scanState: .scanning
        )
    )
    let secondFolder = try await store.upsertFolder(
        FolderItem(
            id: FolderID(),
            identity: RemoteItemIdentity(
                sourceID: sourceID,
                shareID: shareID,
                path: RemotePath(displayPath: "\\music\\albums"),
                modifiedAt: testDate(2)
            ),
            name: "Albums Updated",
            scanState: .complete
        )
    )

    #expect(secondFolder.id == firstFolder.id)
    #expect(try await store.folder(id: firstFolder.id)?.scanState == .complete)

    let mediaIdentity = identity(sourceID: sourceID, shareID: shareID, path: "Music/Albums/Track.mp3", size: 123)
    let firstMedia = try await store.upsertMediaItem(
        MediaItem(
            id: MediaItemID(),
            identity: mediaIdentity,
            parentFolderID: firstFolder.id,
            mediaKind: .audio,
            fileName: "Track.mp3",
            title: "Test Track",
            artist: "Artist",
            album: "Album",
            genre: "Progressive Rock",
            trackNumber: 7,
            discNumber: 2,
            duration: 180,
            artworkURL: URL(string: "file:///tmp/cover.jpg"),
            isFavorite: true,
            playbackCapability: .cacheRequired
        )
    )
    let secondMedia = try await store.upsertMediaItem(
        MediaItem(
            id: MediaItemID(),
            identity: mediaIdentity,
            parentFolderID: firstFolder.id,
            mediaKind: .audio,
            fileName: "Track.mp3",
            title: "Updated Track",
            artist: "Artist",
            album: "Album",
            genre: "Progressive Rock",
            trackNumber: 7,
            discNumber: 2,
            artworkURL: URL(string: "file:///tmp/cover.jpg"),
            isFavorite: true
        )
    )

    #expect(secondMedia.id == firstMedia.id)
    let storedMedia = try await store.mediaItem(id: firstMedia.id)
    #expect(storedMedia?.genre == "Progressive Rock")
    #expect(storedMedia?.trackNumber == 7)
    #expect(storedMedia?.discNumber == 2)
    #expect(storedMedia?.artworkURL?.path == "/tmp/cover.jpg")
    #expect(storedMedia?.isFavorite == true)

    let children = try await store.children(of: firstFolder.id)
    #expect(children.folders.isEmpty)
    #expect(children.mediaItems.map(\.id) == [firstMedia.id])

    let searchResult = try await store.search(LibrarySearchQuery(text: "progressive", mediaKinds: [.audio]))
    #expect(searchResult.mediaItems.map(\.id) == [firstMedia.id])
}

@Test func mediaStoreCanBulkListReplaceAndDeleteMediaItems() async throws {
    let store = MediaStore(configuration: .inMemory())
    let firstSourceID = SourceID()
    let secondSourceID = SourceID()
    let shareID = ShareID()
    let first = MediaItem(
        identity: identity(sourceID: firstSourceID, shareID: shareID, path: "Music/First.flac", size: 1),
        mediaKind: .audio,
        fileName: "First.flac",
        title: "First"
    )
    let second = MediaItem(
        identity: identity(sourceID: secondSourceID, shareID: shareID, path: "Music/Second.flac", size: 2),
        mediaKind: .audio,
        fileName: "Second.flac",
        title: "Second"
    )
    try await store.replaceAllMediaItems([first, second])
    #expect(try await store.listMediaItems().count == 2)
    #expect(try await store.listMediaItems(sourceID: firstSourceID).map(\.title) == ["First"])

    let replacement = MediaItem(
        identity: identity(sourceID: firstSourceID, shareID: shareID, path: "Music/Replaced.flac", size: 3),
        mediaKind: .audio,
        fileName: "Replaced.flac",
        title: "Replaced"
    )
    try await store.replaceMediaItems([replacement], for: firstSourceID)
    #expect(try await store.listMediaItems().compactMap(\.title).sorted() == ["Replaced", "Second"])

    try await store.deleteMediaItems(sourceID: secondSourceID)
    #expect(try await store.listMediaItems().compactMap(\.title) == ["Replaced"])
}

@Test func mediaStorePersistsPlaylistQueueCacheAndScanCheckpoint() async throws {
    let store = MediaStore(configuration: .inMemory())
    let sourceID = SourceID()
    let shareID = ShareID()
    let mediaID = MediaItemID()
    let folderID = FolderID()
    let remoteIdentity = identity(sourceID: sourceID, shareID: shareID, path: "Music/Track.flac", size: 456)

    let playlist = Playlist(
        name: "Favorites",
        entries: [
            PlaylistEntry(target: .media(mediaID), position: 0, title: "Track"),
            PlaylistEntry(target: .folder(folderID, recursive: true), position: 1, title: "Folder")
        ],
        createdAt: testDate(0),
        updatedAt: testDate(1)
    )
    try await store.upsertPlaylist(playlist)
    #expect(try await store.playlist(id: playlist.id)?.entries.count == 2)

    let queue = QueueSnapshot(
        items: [QueueEntry(mediaItemID: mediaID, title: "Track")],
        currentIndex: 0,
        isShuffled: true,
        repeatMode: .all,
        updatedAt: testDate(2)
    )
    try await store.saveQueueSnapshot(queue)
    #expect(try await store.loadQueueSnapshot()?.repeatMode == .all)

    let cacheEntry = CacheEntry(
        mediaItemID: mediaID,
        identity: remoteIdentity,
        state: .cached,
        localFileURL: URL(fileURLWithPath: "/tmp/Track.flac"),
        bytesTotal: 456,
        bytesDone: 456,
        requiredBy: [.manual]
    )
    let storedCacheEntry = try await store.upsertCacheEntry(cacheEntry)
    #expect(try await store.cacheEntry(for: mediaID)?.id == storedCacheEntry.id)
    #expect(try await store.cacheRecord(for: mediaID)?.state == .cached)

    let request = ScanRequest(sourceID: sourceID, shareID: shareID, rootPath: RemotePath(displayPath: "Music"))
    let checkpoint = ScanCheckpoint(
        request: request,
        progress: ScanProgress(
            scanID: ScanID(),
            foldersVisited: 3,
            filesVisited: 7,
            mediaItemsFound: 5,
            currentPath: RemotePath(displayPath: "Music/Albums"),
            isCheckpointed: true
        ),
        updatedAt: testDate(3)
    )
    try await store.saveScanCheckpoint(checkpoint)

    let loaded = try await store.scanCheckpoint(for: request)
    #expect(loaded?.progress.filesVisited == 7)
    #expect(loaded?.request.stableKey == request.stableKey)
}

private func identity(
    sourceID: SourceID,
    shareID: ShareID,
    path: String,
    size: Int64? = nil,
    modifiedAt: Date = testDate(2)
) -> RemoteItemIdentity {
    RemoteItemIdentity(
        sourceID: sourceID,
        shareID: shareID,
        path: RemotePath(displayPath: path),
        size: size,
        modifiedAt: modifiedAt
    )
}

private func testDate(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset)
}
