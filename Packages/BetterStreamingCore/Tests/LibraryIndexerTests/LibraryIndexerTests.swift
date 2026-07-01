import Foundation
import Testing
import BetterStreamingDomain
import LibraryIndexer
import TestSupport

@Test func scannerTraversesFoldersAndClassifiesMediaInDeterministicOrder() async throws {
    let fileSystem = try FakeRemoteFileSystem(rootChildren: [
        .directory(".Trash-1000", children: [
            .file("ignored.mp3", data: Data([1]))
        ]),
        .directory("@eaDir", children: [
            .file("metadata.flac", data: Data([1]))
        ]),
        .file("._01 Intro.MP3", data: Data([1])),
        .file("desktop.ini", data: Data([1])),
        .file("notes.txt"),
        .directory("Album 10", children: [
            .file("clip.mkv", data: Data([1, 2, 3]))
        ]),
        .file("movie.MP4", data: Data([1])),
        .directory("Album 2", children: [
            .file("Track 10.flac", data: Data([1, 2])),
            .file("Track 2.flac", data: Data([1]))
        ]),
        .file("01 Intro.MP3", data: Data([1, 2, 3, 4])),
        .file("cover.jpg")
    ])
    let scanner = RemoteLibraryScanner(fileSystem: fileSystem)
    let request = scanRequest()

    let report = try await scanner.scan(request)

    #expect(report.folders.map(\.path.displayPath) == ["", "Album 2", "Album 10"])
    #expect(report.mediaFiles.map(\.name) == [
        "01 Intro.MP3",
        "movie.MP4",
        "Track 2.flac",
        "Track 10.flac",
        "clip.mkv"
    ])
    #expect(report.mediaFiles.map(\.mediaKind) == [.audio, .video, .audio, .audio, .video])
    #expect(report.filesVisited == 7)
    #expect(report.mediaItemsFound == 5)
    #expect(report.finalCheckpoint.pendingDirectories.isEmpty)
    #expect(report.finalCheckpoint.visitedDirectories.map(\.displayPath) == ["", "Album 2", "Album 10"])
}

@Test func scannerEmitsCheckpointsAndProgress() async throws {
    let fileSystem = try FakeRemoteFileSystem(rootChildren: [
        .directory("A", children: [
            .file("one.mp3")
        ]),
        .directory("B", children: [
            .file("two.mp3")
        ])
    ])
    let scanner = RemoteLibraryScanner(fileSystem: fileSystem, checkpointEveryFolderCount: 1)
    let collector = ScanEventCollector()

    _ = try await scanner.scan(scanRequest()) { event in
        await collector.append(event)
    }

    let events = await collector.snapshot()
    let checkpointCount = events.filter { event in
        if case .checkpoint = event {
            return true
        }
        return false
    }.count
    let progressCount = events.filter { event in
        if case .progress = event {
            return true
        }
        return false
    }.count

    #expect(checkpointCount == 3)
    #expect(progressCount == 3)
    #expect(events.first == .started(events.scanID))
}

@Test func scannerCanResumeFromCheckpointWithoutRevisitingCompletedFolders() async throws {
    let root = RemotePath(displayPath: "")
    let albumA = RemotePath(displayPath: "A")
    let albumB = RemotePath(displayPath: "B")
    let request = scanRequest(rootPath: root)
    let checkpoint = LibraryScanCheckpoint(
        scanID: ScanID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        request: request,
        pendingDirectories: [albumB],
        visitedDirectories: [root, albumA],
        foldersVisited: 2,
        filesVisited: 1,
        mediaItemsFound: 1,
        currentPath: albumA
    )
    let fileSystem = try FakeRemoteFileSystem(rootChildren: [
        .directory("A", children: [
            .file("old.mp3")
        ]),
        .directory("B", children: [
            .file("new.mp3")
        ])
    ])
    let scanner = RemoteLibraryScanner(fileSystem: fileSystem)

    let report = try await scanner.scan(request, resumingFrom: checkpoint)

    #expect(report.scanID == checkpoint.scanID)
    #expect(report.folders.map(\.path.displayPath) == ["B"])
    #expect(report.mediaFiles.map(\.name) == ["new.mp3"])
    #expect(report.finalCheckpoint.foldersVisited == 3)
    #expect(report.finalCheckpoint.mediaItemsFound == 2)
}

@Test func scannerResumeRescansInFlightDirectoryDroppedFromPending() async throws {
    // A checkpoint taken mid-directory records `currentPath` but had already
    // popped it off `pendingDirectories` and hadn't marked it visited. Resuming
    // must re-scan it (and its subtree) rather than silently losing it.
    let root = RemotePath(displayPath: "")
    let albumA = RemotePath(displayPath: "A")
    let albumB = RemotePath(displayPath: "B")
    let request = scanRequest(rootPath: root)
    let checkpoint = LibraryScanCheckpoint(
        scanID: ScanID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
        request: request,
        pendingDirectories: [albumB],
        visitedDirectories: [root],
        foldersVisited: 1,
        filesVisited: 0,
        mediaItemsFound: 0,
        currentPath: albumA   // in flight when interrupted; not visited, not pending
    )
    let fileSystem = try FakeRemoteFileSystem(rootChildren: [
        .directory("A", children: [.file("a.mp3")]),
        .directory("B", children: [.file("b.mp3")])
    ])
    let scanner = RemoteLibraryScanner(fileSystem: fileSystem)

    let report = try await scanner.scan(request, resumingFrom: checkpoint)

    #expect(Set(report.folders.map(\.path.displayPath)) == ["A", "B"])
    #expect(Set(report.mediaFiles.map(\.name)) == ["a.mp3", "b.mp3"])
    #expect(report.finalCheckpoint.foldersVisited == 3)
}

@Test func scannerEmitsCancellationCheckpointWhenRemoteCancels() async throws {
    let album = RemotePath(displayPath: "Album")
    let fileSystem = try FakeRemoteFileSystem(rootChildren: [
        .directory("Album", children: [
            .file("song.mp3")
        ])
    ])
    await fileSystem.setError(.cancelled, for: .list, path: album)

    let scanner = RemoteLibraryScanner(fileSystem: fileSystem)
    let collector = ScanEventCollector()

    do {
        _ = try await scanner.scan(scanRequest()) { event in
            await collector.append(event)
        }
        #expect(Bool(false), "Expected scan to throw")
    } catch let error as RemoteFileSystemError {
        #expect(error == .cancelled)
    }

    let events = await collector.snapshot()
    let cancelledCheckpoint = events.compactMap { event -> LibraryScanCheckpoint? in
        if case .cancelled(let checkpoint) = event {
            return checkpoint
        }
        return nil
    }.first

    #expect(cancelledCheckpoint?.foldersVisited == 1)
    #expect(cancelledCheckpoint?.pendingDirectories.isEmpty == true)
    #expect(cancelledCheckpoint?.currentPath?.displayPath == "Album")
}

@Test func mediaFileClassifierIsCaseInsensitiveAndRejectsUnknownExtensions() {
    let classifier = MediaFileClassifier()

    #expect(classifier.classify(fileName: "SONG.FLAC") == .audio)
    #expect(classifier.classify(fileName: "Movie.Mp4") == .video)
    #expect(classifier.classify(fileName: "._SONG.FLAC") == nil)
    #expect(classifier.classify(fileName: ".hidden.mp3") == nil)
    #expect(classifier.classify(fileName: "desktop.ini") == nil)
    #expect(classifier.classify(fileName: "Thumbs.db") == nil)
    #expect(classifier.classify(fileName: "cover.jpg") == nil)
    #expect(classifier.classify(fileName: "README") == nil)
}

private func scanRequest(rootPath: RemotePath = RemotePath(displayPath: "")) -> ScanRequest {
    ScanRequest(sourceID: SourceID(), shareID: ShareID(), rootPath: rootPath)
}

private actor ScanEventCollector {
    private var events: [LibraryScanEvent] = []

    func append(_ event: LibraryScanEvent) {
        events.append(event)
    }

    func snapshot() -> [LibraryScanEvent] {
        events
    }
}

private extension [LibraryScanEvent] {
    var scanID: ScanID {
        for event in self {
            if case .started(let scanID) = event {
                return scanID
            }
        }

        return ScanID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
    }
}
