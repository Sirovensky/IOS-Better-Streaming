import Foundation
import BetterStreamingDomain
import RemoteFileSystem

public struct LibraryScanCheckpoint: Hashable, Codable, Sendable {
    public var scanID: ScanID
    public var request: ScanRequest
    public var pendingDirectories: [RemotePath]
    public var visitedDirectories: [RemotePath]
    public var foldersVisited: Int
    public var filesVisited: Int
    public var mediaItemsFound: Int
    public var currentPath: RemotePath?
    public var updatedAt: Date

    public init(
        scanID: ScanID,
        request: ScanRequest,
        pendingDirectories: [RemotePath],
        visitedDirectories: [RemotePath],
        foldersVisited: Int,
        filesVisited: Int,
        mediaItemsFound: Int,
        currentPath: RemotePath?,
        updatedAt: Date = Date()
    ) {
        self.scanID = scanID
        self.request = request
        self.pendingDirectories = pendingDirectories
        self.visitedDirectories = visitedDirectories
        self.foldersVisited = foldersVisited
        self.filesVisited = filesVisited
        self.mediaItemsFound = mediaItemsFound
        self.currentPath = currentPath
        self.updatedAt = updatedAt
    }
}

public enum IndexedMediaKind: String, Hashable, Codable, Sendable {
    case audio
    case video
}

public struct ScannedFolder: Hashable, Codable, Sendable {
    public var path: RemotePath
    public var parentPath: RemotePath?
    public var name: String
    public var sortKey: String
    public var scanState: ScanState
    public var directChildFolderCount: Int
    public var directMediaFileCount: Int

    public init(
        path: RemotePath,
        parentPath: RemotePath?,
        name: String,
        sortKey: String,
        scanState: ScanState,
        directChildFolderCount: Int,
        directMediaFileCount: Int
    ) {
        self.path = path
        self.parentPath = parentPath
        self.name = name
        self.sortKey = sortKey
        self.scanState = scanState
        self.directChildFolderCount = directChildFolderCount
        self.directMediaFileCount = directMediaFileCount
    }
}

public struct ScannedMediaFile: Hashable, Codable, Sendable {
    public var path: RemotePath
    public var parentPath: RemotePath?
    public var name: String
    public var mediaKind: IndexedMediaKind
    public var size: Int64?
    public var modifiedAt: Date?
    public var contentType: String?
    public var remoteFileID: RemoteFileID?
    public var sortKey: String

    public init(
        path: RemotePath,
        parentPath: RemotePath?,
        name: String,
        mediaKind: IndexedMediaKind,
        size: Int64?,
        modifiedAt: Date?,
        contentType: String?,
        remoteFileID: RemoteFileID?,
        sortKey: String
    ) {
        self.path = path
        self.parentPath = parentPath
        self.name = name
        self.mediaKind = mediaKind
        self.size = size
        self.modifiedAt = modifiedAt
        self.contentType = contentType
        self.remoteFileID = remoteFileID
        self.sortKey = sortKey
    }
}

public struct ScanReport: Hashable, Codable, Sendable {
    public var scanID: ScanID
    public var request: ScanRequest
    public var folders: [ScannedFolder]
    public var mediaFiles: [ScannedMediaFile]
    public var filesVisited: Int
    public var mediaItemsFound: Int
    public var finalCheckpoint: LibraryScanCheckpoint
    public var startedAt: Date
    public var finishedAt: Date

    public init(
        scanID: ScanID,
        request: ScanRequest,
        folders: [ScannedFolder],
        mediaFiles: [ScannedMediaFile],
        filesVisited: Int,
        mediaItemsFound: Int,
        finalCheckpoint: LibraryScanCheckpoint,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.scanID = scanID
        self.request = request
        self.folders = folders
        self.mediaFiles = mediaFiles
        self.filesVisited = filesVisited
        self.mediaItemsFound = mediaItemsFound
        self.finalCheckpoint = finalCheckpoint
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public enum LibraryScanEvent: Sendable, Hashable {
    case started(ScanID)
    case folderDiscovered(ScannedFolder)
    case mediaDiscovered(ScannedMediaFile)
    case progress(ScanProgress)
    case checkpoint(LibraryScanCheckpoint)
    case completed(ScanReport)
    case cancelled(LibraryScanCheckpoint)
}

public enum LibraryIndexEvent: Sendable, Equatable {
    case started(FolderID)
    case discovered(MediaSummary)
    case completed(FolderID)
}

public protocol LibraryIndexing: Sendable {
    func scan(folderID: FolderID) -> AsyncThrowingStream<LibraryIndexEvent, Error>
}

public struct MediaFileClassifier: Sendable {
    public static let audioExtensions: Set<String> = [
        "aac", "aif", "aiff", "alac", "flac", "m4a", "m4b", "mp3", "oga", "ogg", "opus", "wav", "wma"
    ]

    public static let videoExtensions: Set<String> = [
        "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "ts", "webm", "wmv"
    ]

    public init() {}

    public func classify(_ entry: RemoteEntry) -> IndexedMediaKind? {
        guard entry.kind == .file else {
            return nil
        }

        return classify(fileName: entry.name)
    }

    public func classify(path: RemotePath) -> IndexedMediaKind? {
        classify(fileName: path.lastPathComponent)
    }

    public func classify(fileName: String) -> IndexedMediaKind? {
        guard LibraryScanFilter().shouldIndexFileName(fileName) else {
            return nil
        }

        guard let fileExtension = fileName.split(separator: ".").last.map(String.init), fileExtension != fileName else {
            return nil
        }

        let normalizedExtension = fileExtension.lowercased()
        if Self.audioExtensions.contains(normalizedExtension) {
            return .audio
        }
        if Self.videoExtensions.contains(normalizedExtension) {
            return .video
        }
        return nil
    }
}

public struct LibraryScanFilter: Sendable {
    public init() {}

    public func shouldIndex(_ entry: RemoteEntry) -> Bool {
        switch entry.kind {
        case .directory:
            return shouldDescendIntoDirectoryName(entry.name)
        case .file:
            return shouldIndexFileName(entry.name)
        case .symbolicLink, .unknown:
            return false
        }
    }

    public func shouldIndexFileName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(".") else {
            return false
        }

        switch trimmed.lowercased() {
        case "thumbs.db", "desktop.ini":
            return false
        default:
            return true
        }
    }

    public func shouldDescendIntoDirectoryName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(".") else {
            return false
        }

        switch trimmed.lowercased() {
        case "@eadir", "#recycle", "$recycle.bin", "recycle bin", "network trash folder", "temporary items":
            return false
        default:
            return true
        }
    }
}

public struct RemoteLibraryScanner: Sendable {
    public typealias EventSink = @Sendable (LibraryScanEvent) async -> Void

    private let fileSystem: any RemoteFileSystemClient
    private let classifier: MediaFileClassifier
    private let filter: LibraryScanFilter
    private let checkpointEveryFolderCount: Int

    public init(
        fileSystem: any RemoteFileSystemClient,
        classifier: MediaFileClassifier = MediaFileClassifier(),
        filter: LibraryScanFilter = LibraryScanFilter(),
        checkpointEveryFolderCount: Int = 1
    ) {
        self.fileSystem = fileSystem
        self.classifier = classifier
        self.filter = filter
        self.checkpointEveryFolderCount = max(1, checkpointEveryFolderCount)
    }

    public func events(
        for request: ScanRequest,
        resumingFrom checkpoint: LibraryScanCheckpoint? = nil
    ) -> AsyncThrowingStream<LibraryScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await scan(request, resumingFrom: checkpoint) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func scan(
        _ request: ScanRequest,
        resumingFrom checkpoint: LibraryScanCheckpoint? = nil,
        onEvent: EventSink? = nil
    ) async throws -> ScanReport {
        let scanID = checkpoint?.scanID ?? ScanID()
        let startedAt = Date()
        var pendingDirectories = checkpoint?.pendingDirectories ?? [request.rootPath]
        var visitedDirectories = checkpoint?.visitedDirectories ?? []
        var visitedNormalizedPaths = Set(visitedDirectories.map(\.normalizedPath))

        // A checkpoint taken mid-directory records that directory as `currentPath`
        // but drops it from `pendingDirectories` (it had been popped) without
        // marking it visited — so resuming would lose its entire subtree. Re-seed
        // it when it is neither visited nor already pending.
        if let currentPath = checkpoint?.currentPath,
           !visitedNormalizedPaths.contains(currentPath.normalizedPath),
           !pendingDirectories.contains(where: { $0.normalizedPath == currentPath.normalizedPath }) {
            pendingDirectories.append(currentPath)
        }
        var foldersVisited = checkpoint?.foldersVisited ?? 0
        var filesVisited = checkpoint?.filesVisited ?? 0
        var mediaItemsFound = checkpoint?.mediaItemsFound ?? 0
        var folders: [ScannedFolder] = []
        var mediaFiles: [ScannedMediaFile] = []
        var latestCheckpoint = makeCheckpoint(
            scanID: scanID,
            request: request,
            pendingDirectories: pendingDirectories,
            visitedDirectories: visitedDirectories,
            foldersVisited: foldersVisited,
            filesVisited: filesVisited,
            mediaItemsFound: mediaItemsFound,
            currentPath: checkpoint?.currentPath
        )

        await onEvent?(.started(scanID))

        do {
            while let directoryPath = pendingDirectories.popLast() {
                try Task.checkCancellation()

                guard !visitedNormalizedPaths.contains(directoryPath.normalizedPath) else {
                    latestCheckpoint = makeCheckpoint(
                        scanID: scanID,
                        request: request,
                        pendingDirectories: pendingDirectories,
                        visitedDirectories: visitedDirectories,
                        foldersVisited: foldersVisited,
                        filesVisited: filesVisited,
                        mediaItemsFound: mediaItemsFound,
                        currentPath: directoryPath
                    )
                    continue
                }

                latestCheckpoint = makeCheckpoint(
                    scanID: scanID,
                    request: request,
                    pendingDirectories: pendingDirectories,
                    visitedDirectories: visitedDirectories,
                    foldersVisited: foldersVisited,
                    filesVisited: filesVisited,
                    mediaItemsFound: mediaItemsFound,
                    currentPath: directoryPath
                )

                let entries = try await fileSystem.list(directoryPath)
                    .filter { filter.shouldIndex($0) }
                    .sortedDeterministically()
                try Task.checkCancellation()

                let directDirectories = entries.filter { $0.kind == .directory }
                let directFiles = entries.filter { $0.kind == .file }
                let directMediaFiles = directFiles.compactMap { entry -> ScannedMediaFile? in
                    guard let mediaKind = classifier.classify(entry) else {
                        return nil
                    }

                    return ScannedMediaFile(
                        path: entry.path,
                        parentPath: directoryPath,
                        name: entry.name,
                        mediaKind: mediaKind,
                        size: entry.size,
                        modifiedAt: entry.modifiedAt,
                        contentType: entry.contentType,
                        remoteFileID: entry.fileID,
                        sortKey: RemoteEntrySort.sortKey(for: entry.name)
                    )
                }

                let scannedFolder = ScannedFolder(
                    path: directoryPath,
                    parentPath: directoryPath.parentPath,
                    name: directoryPath.lastPathComponent,
                    sortKey: RemoteEntrySort.sortKey(for: directoryPath.lastPathComponent),
                    scanState: .complete,
                    directChildFolderCount: directDirectories.count,
                    directMediaFileCount: directMediaFiles.count
                )

                folders.append(scannedFolder)
                await onEvent?(.folderDiscovered(scannedFolder))

                for mediaFile in directMediaFiles {
                    try Task.checkCancellation()
                    mediaFiles.append(mediaFile)
                    await onEvent?(.mediaDiscovered(mediaFile))
                }

                foldersVisited += 1
                filesVisited += directFiles.count
                mediaItemsFound += directMediaFiles.count
                visitedDirectories.append(directoryPath)
                visitedNormalizedPaths.insert(directoryPath.normalizedPath)

                for childDirectory in directDirectories.reversed() where !visitedNormalizedPaths.contains(childDirectory.path.normalizedPath) {
                    pendingDirectories.append(childDirectory.path)
                }

                latestCheckpoint = makeCheckpoint(
                    scanID: scanID,
                    request: request,
                    pendingDirectories: pendingDirectories,
                    visitedDirectories: visitedDirectories,
                    foldersVisited: foldersVisited,
                    filesVisited: filesVisited,
                    mediaItemsFound: mediaItemsFound,
                    currentPath: directoryPath
                )

                let shouldEmitCheckpoint = foldersVisited % checkpointEveryFolderCount == 0
                if shouldEmitCheckpoint {
                    await onEvent?(.checkpoint(latestCheckpoint))
                }
                await onEvent?(.progress(ScanProgress(
                    scanID: scanID,
                    foldersVisited: foldersVisited,
                    filesVisited: filesVisited,
                    mediaItemsFound: mediaItemsFound,
                    currentPath: directoryPath,
                    isCheckpointed: shouldEmitCheckpoint
                )))
            }
        } catch is CancellationError {
            latestCheckpoint = makeCheckpoint(
                scanID: scanID,
                request: request,
                pendingDirectories: pendingDirectories,
                visitedDirectories: visitedDirectories,
                foldersVisited: foldersVisited,
                filesVisited: filesVisited,
                mediaItemsFound: mediaItemsFound,
                currentPath: latestCheckpoint.currentPath
            )
            await onEvent?(.cancelled(latestCheckpoint))
            throw CancellationError()
        } catch RemoteFileSystemError.cancelled {
            latestCheckpoint = makeCheckpoint(
                scanID: scanID,
                request: request,
                pendingDirectories: pendingDirectories,
                visitedDirectories: visitedDirectories,
                foldersVisited: foldersVisited,
                filesVisited: filesVisited,
                mediaItemsFound: mediaItemsFound,
                currentPath: latestCheckpoint.currentPath
            )
            await onEvent?(.cancelled(latestCheckpoint))
            throw RemoteFileSystemError.cancelled
        }

        latestCheckpoint = makeCheckpoint(
            scanID: scanID,
            request: request,
            pendingDirectories: [],
            visitedDirectories: visitedDirectories,
            foldersVisited: foldersVisited,
            filesVisited: filesVisited,
            mediaItemsFound: mediaItemsFound,
            currentPath: nil
        )

        let report = ScanReport(
            scanID: scanID,
            request: request,
            folders: folders,
            mediaFiles: mediaFiles,
            filesVisited: filesVisited,
            mediaItemsFound: mediaItemsFound,
            finalCheckpoint: latestCheckpoint,
            startedAt: startedAt,
            finishedAt: Date()
        )

        await onEvent?(.completed(report))
        return report
    }

    private func makeCheckpoint(
        scanID: ScanID,
        request: ScanRequest,
        pendingDirectories: [RemotePath],
        visitedDirectories: [RemotePath],
        foldersVisited: Int,
        filesVisited: Int,
        mediaItemsFound: Int,
        currentPath: RemotePath?
    ) -> LibraryScanCheckpoint {
        LibraryScanCheckpoint(
            scanID: scanID,
            request: request,
            pendingDirectories: pendingDirectories,
            visitedDirectories: visitedDirectories,
            foldersVisited: foldersVisited,
            filesVisited: filesVisited,
            mediaItemsFound: mediaItemsFound,
            currentPath: currentPath
        )
    }
}
