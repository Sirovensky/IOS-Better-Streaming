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

@Test func metadataOverrideOverlaysAndSurvivesRescan() async throws {
    let store = MediaStore(configuration: .inMemory())
    let sourceID = SourceID()
    let shareID = ShareID()
    let id = identity(sourceID: sourceID, shareID: shareID, path: "Music/Track.mp3", size: 10)

    let scanned = MediaItem(
        identity: id, mediaKind: .audio, fileName: "Track.mp3",
        title: "Bad Title", artist: "Unknown Artist", album: "Unknown", genre: "Unknown"
    )
    try await store.replaceMediaItems([scanned], for: sourceID)

    // A partial override on the same identity key (title + artist only).
    try await store.upsertMetadataOverride(
        MetadataOverride(identityKey: id.stableKey, title: "Real Title", artist: "Real Artist", updatedAt: testDate(0))
    )

    // Overlay applies on list; un-overridden album keeps the scanned value.
    let overlaid = try await store.listMediaItems().first
    #expect(overlaid?.title == "Real Title")
    #expect(overlaid?.artist == "Real Artist")
    #expect(overlaid?.album == "Unknown")

    // A rescan rewrites the base row from file tags...
    try await store.replaceMediaItems([scanned], for: sourceID)
    // ...but the override still overlays (the durability guarantee).
    let afterRescan = try await store.mediaItem(identityKey: id.stableKey)
    #expect(afterRescan?.title == "Real Title")
    #expect(afterRescan?.artist == "Real Artist")

    // Clearing the override restores the scanned values.
    try await store.deleteMetadataOverride(identityKey: id.stableKey)
    let cleared = try await store.mediaItem(identityKey: id.stableKey)
    #expect(cleared?.title == "Bad Title")
    #expect(try await store.listMetadataOverrides().isEmpty)
}

/// Regression: the maintenance writes (duration on play, artwork on backfill,
/// favorite) must update ONLY their own column and never rewrite the base text
/// columns from the edited overlay — otherwise "revert to file tags" would
/// restore the edit instead of the original tags.
@Test func columnScopedWritesDoNotPoisonBaseTextColumns() async throws {
    let store = MediaStore(configuration: .inMemory())
    let sourceID = SourceID()
    let shareID = ShareID()
    let id = identity(sourceID: sourceID, shareID: shareID, path: "Music/Track.mp3", size: 10)

    let scanned = MediaItem(
        identity: id, mediaKind: .audio, fileName: "Track.mp3",
        title: "File Title", artist: "File Artist", album: "File Album", genre: "Rock"
    )
    try await store.replaceMediaItems([scanned], for: sourceID)

    // User edits the tags → override overlays on the file-tag base row.
    try await store.upsertMetadataOverride(
        MetadataOverride(identityKey: id.stableKey, title: "Edited Title",
                         artist: "Edited Artist", album: "Edited Album", updatedAt: testDate(0))
    )
    #expect(try await store.mediaItem(identityKey: id.stableKey)?.title == "Edited Title")

    // Maintenance writes (these used to full-row upsert the edited in-memory values).
    try await store.setDuration(321, identityKey: id.stableKey)
    try await store.setArtworkURL("file:///art.jpg", identityKey: id.stableKey)
    try await store.setFavorite(true, identityKey: id.stableKey)

    // Overlay still shows the edit; the scoped columns took the new values.
    let edited = try await store.mediaItem(identityKey: id.stableKey)
    #expect(edited?.title == "Edited Title")
    #expect(edited?.duration == 321)
    #expect(edited?.isFavorite == true)

    // Revert restores the ORIGINAL file tags (a poisoned base row would return the
    // edited values here), and the scoped columns survive the revert.
    try await store.deleteMetadataOverride(identityKey: id.stableKey)
    let reverted = try await store.mediaItem(identityKey: id.stableKey)
    #expect(reverted?.title == "File Title")
    #expect(reverted?.artist == "File Artist")
    #expect(reverted?.album == "File Album")
    #expect(reverted?.duration == 321)
    #expect(reverted?.isFavorite == true)
    #expect(reverted?.artworkURL?.absoluteString == "file:///art.jpg")
}

/// Regression: a non-destructive rescan must preserve a surviving track's PK `id`
/// AND its `cache_entries` row. The bulk test above only covers the swap-to-a-new
/// -identity branch (insert + delete), never the survive branch.
@Test func replaceMediaItemsPreservesSurvivingIDAndCacheEntry() async throws {
    let store = MediaStore(configuration: .inMemory())
    let sourceID = SourceID()
    let shareID = ShareID()
    let survivorIdentity = identity(sourceID: sourceID, shareID: shareID, path: "Music/Survivor.flac", size: 1)

    let survivor = MediaItem(
        identity: survivorIdentity, mediaKind: .audio, fileName: "Survivor.flac", title: "Survivor"
    )
    let stored = try await store.replaceMediaItems([survivor], for: sourceID).first
    let survivorID = try #require(stored?.id)

    try await store.upsertCacheEntry(
        CacheEntry(
            mediaItemID: survivorID,
            identity: survivorIdentity,
            state: .cached,
            localFileURL: URL(fileURLWithPath: "/tmp/Survivor.flac"),
            bytesTotal: 1,
            bytesDone: 1,
            requiredBy: [.manual]
        )
    )

    // Rescan: the survivor returns (same identity) alongside a brand-new track.
    let newcomer = MediaItem(
        identity: identity(sourceID: sourceID, shareID: shareID, path: "Music/Newcomer.flac", size: 2),
        mediaKind: .audio, fileName: "Newcomer.flac", title: "Newcomer"
    )
    try await store.replaceMediaItems([survivor, newcomer], for: sourceID)

    // (a) the survivor kept its PK, and (b) its cache entry survived the rescan.
    #expect(try await store.mediaItem(matching: survivorIdentity)?.id == survivorID)
    #expect(try await store.cacheEntry(for: survivorID)?.state == .cached)
    #expect(try await store.listMediaItems(sourceID: sourceID).count == 2)
}

/// Regression for the override durability guarantee under identity drift: a server
/// re-tag or NAS mtime/size drift mints a NEW full `stableKey` for the same file.
/// The override (keyed on the old key) must STILL overlay via the path-stable
/// fallback, and must not be pruned by the rescan's delete pass.
@Test func metadataOverrideSurvivesIdentityKeyChange() async throws {
    let store = MediaStore(configuration: .inMemory())
    let sourceID = SourceID()
    let shareID = ShareID()
    let original = identity(sourceID: sourceID, shareID: shareID, path: "Music/Track.mp3", size: 10)

    let scanned = MediaItem(
        identity: original, mediaKind: .audio, fileName: "Track.mp3",
        title: "Bad Title", artist: "Unknown Artist"
    )
    try await store.replaceMediaItems([scanned], for: sourceID)
    try await store.upsertMetadataOverride(
        MetadataOverride(identityKey: original.stableKey, title: "Real Title", artist: "Real Artist", updatedAt: testDate(0))
    )

    // Same logical file, drifted size + mtime → a different stableKey.
    let drifted = identity(sourceID: sourceID, shareID: shareID, path: "Music/Track.mp3", size: 20, modifiedAt: testDate(99))
    #expect(drifted.stableKey != original.stableKey)
    let rescanned = MediaItem(
        identity: drifted, mediaKind: .audio, fileName: "Track.mp3",
        title: "Bad Title", artist: "Unknown Artist"
    )
    try await store.replaceMediaItems([rescanned], for: sourceID)

    // The override still overlays via the path-stable fallback, and wasn't pruned.
    let overlaid = try await store.mediaItem(identityKey: drifted.stableKey)
    #expect(overlaid?.title == "Real Title")
    #expect(overlaid?.artist == "Real Artist")
    #expect(try await store.listMetadataOverrides().count == 1)
}

/// An override whose fields are empty/whitespace-only must NOT blank the scanned
/// values — empty fields count as unset on both write and overlay.
@Test func emptyOverrideFieldsDoNotBlankScannedValues() async throws {
    let store = MediaStore(configuration: .inMemory())
    let sourceID = SourceID()
    let shareID = ShareID()
    let id = identity(sourceID: sourceID, shareID: shareID, path: "Music/Track.mp3", size: 10)

    let scanned = MediaItem(
        identity: id, mediaKind: .audio, fileName: "Track.mp3",
        title: "File Title", artist: "File Artist"
    )
    try await store.replaceMediaItems([scanned], for: sourceID)

    try await store.upsertMetadataOverride(
        MetadataOverride(identityKey: id.stableKey, title: "  ", artist: "Real Artist", updatedAt: testDate(0))
    )

    let overlaid = try await store.mediaItem(identityKey: id.stableKey)
    #expect(overlaid?.title == "File Title")   // blank override left the scanned title
    #expect(overlaid?.artist == "Real Artist") // non-blank override applied
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
