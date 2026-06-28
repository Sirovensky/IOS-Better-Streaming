import Foundation
import Testing
import BetterStreamingDomain
import RemoteFileSystem
import TestSupport

@Test func fakeFileSystemReadsByteRanges() async throws {
    let path = RemotePath(displayPath: "song.mp3")
    let fileSystem = FakeRemoteFileSystem(fileDataByPath: [path: Data("abcdef".utf8)])
    let data = try await fileSystem.read(path, range: 1..<4)
    #expect(String(decoding: data, as: UTF8.self) == "bcd")
}

@Test func fakeTreeListsDirectChildrenInDeterministicNaturalOrder() async throws {
    let fileSystem = try FakeRemoteFileSystem(rootChildren: [
        .file("track 10.mp3"),
        .directory("Disc 2"),
        .file("track 2.mp3"),
        .directory("Disc 10"),
        .file("notes.txt")
    ])

    let entries = try await fileSystem.list(RemotePath(displayPath: ""))

    #expect(entries.map(\.name) == [
        "Disc 2",
        "Disc 10",
        "notes.txt",
        "track 2.mp3",
        "track 10.mp3"
    ])
}

@Test func fakeTreeStatsFilesAndUsesNormalizedPaths() async throws {
    let modifiedAt = Date(timeIntervalSince1970: 100)
    let fileSystem = try FakeRemoteFileSystem(rootChildren: [
        .directory("Music", children: [
            .file("Song.MP3", data: Data("payload".utf8), modifiedAt: modifiedAt, contentType: "audio/mpeg")
        ])
    ])

    let metadata = try await fileSystem.stat(RemotePath(displayPath: "music/song.mp3"))

    #expect(metadata.kind == .file)
    #expect(metadata.size == 7)
    #expect(metadata.modifiedAt == modifiedAt)
    #expect(metadata.contentType == "audio/mpeg")
}

@Test func fakeFileSystemDownloadsAtomicallyAndReportsProgress() async throws {
    let path = RemotePath(displayPath: "song.mp3")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let destination = directory.appendingPathComponent("song.mp3")
    let fileSystem = FakeRemoteFileSystem(fileDataByPath: [path: Data("abcdef".utf8)])
    let progress = ProgressCollector()

    try await fileSystem.download(path, to: destination) { update in
        await progress.append(update)
    }

    let downloaded = try Data(contentsOf: destination)
    let updates = await progress.snapshot()

    #expect(downloaded == Data("abcdef".utf8))
    #expect(updates == [TransferProgress(completedBytes: 6, totalBytes: 6)])
}

@Test func fakeFileSystemCanInjectOperationErrors() async throws {
    let path = RemotePath(displayPath: "blocked.mp3")
    let fileSystem = FakeRemoteFileSystem(fileDataByPath: [path: Data("abcdef".utf8)])
    await fileSystem.setError(.permissionDenied(path), for: .read, path: path)

    do {
        _ = try await fileSystem.read(path, range: 0..<1)
        #expect(Bool(false), "Expected read to throw")
    } catch let error as RemoteFileSystemError {
        #expect(error == .permissionDenied(path))
    }
}

private actor ProgressCollector {
    private var updates: [TransferProgress] = []

    func append(_ update: TransferProgress) {
        updates.append(update)
    }

    func snapshot() -> [TransferProgress] {
        updates
    }
}
