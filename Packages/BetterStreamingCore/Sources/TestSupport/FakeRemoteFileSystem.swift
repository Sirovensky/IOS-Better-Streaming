import Foundation
import BetterStreamingDomain
import RemoteFileSystem

public struct FakeRemoteFile: Hashable, Sendable {
    public var name: String
    public var data: Data
    public var modifiedAt: Date?
    public var contentType: String?
    public var fileID: RemoteFileID?

    public init(
        _ name: String,
        data: Data = Data(),
        modifiedAt: Date? = nil,
        contentType: String? = nil,
        fileID: RemoteFileID? = nil
    ) {
        self.name = name
        self.data = data
        self.modifiedAt = modifiedAt
        self.contentType = contentType
        self.fileID = fileID
    }
}

public struct FakeRemoteDirectory: Hashable, Sendable {
    public var name: String
    public var children: [FakeRemoteNode]
    public var modifiedAt: Date?
    public var fileID: RemoteFileID?

    public init(
        _ name: String,
        children: [FakeRemoteNode] = [],
        modifiedAt: Date? = nil,
        fileID: RemoteFileID? = nil
    ) {
        self.name = name
        self.children = children
        self.modifiedAt = modifiedAt
        self.fileID = fileID
    }
}

public enum FakeRemoteNode: Hashable, Sendable {
    case directory(FakeRemoteDirectory)
    case file(FakeRemoteFile)

    public static func directory(
        _ name: String,
        children: [FakeRemoteNode] = [],
        modifiedAt: Date? = nil,
        fileID: RemoteFileID? = nil
    ) -> FakeRemoteNode {
        .directory(FakeRemoteDirectory(name, children: children, modifiedAt: modifiedAt, fileID: fileID))
    }

    public static func file(
        _ name: String,
        data: Data = Data(),
        modifiedAt: Date? = nil,
        contentType: String? = nil,
        fileID: RemoteFileID? = nil
    ) -> FakeRemoteNode {
        .file(FakeRemoteFile(name, data: data, modifiedAt: modifiedAt, contentType: contentType, fileID: fileID))
    }

    var name: String {
        switch self {
        case .directory(let directory):
            return directory.name
        case .file(let file):
            return file.name
        }
    }
}

public actor FakeRemoteFileSystem: RemoteFileSystemClient {
    public let capabilities: RemoteCapabilities

    private var entriesByNormalizedPath: [String: [RemoteEntry]]
    private var metadataByNormalizedPath: [String: RemoteMetadata]
    private var fileDataByNormalizedPath: [String: Data]
    private var operationErrors: [OperationKey: RemoteFileSystemError]

    public init(
        entriesByPath: [RemotePath: [RemoteEntry]] = [:],
        fileDataByPath: [RemotePath: Data] = [:],
        capabilities: RemoteCapabilities = RemoteCapabilities(supportsByteRangeRead: true)
    ) {
        self.capabilities = capabilities
        entriesByNormalizedPath = [:]
        metadataByNormalizedPath = [:]
        fileDataByNormalizedPath = [:]
        operationErrors = [:]

        let root = RemotePath(displayPath: "")
        metadataByNormalizedPath[root.normalizedPath] = RemoteMetadata(
            path: root,
            kind: .directory,
            supportsRangeRead: capabilities.supportsByteRangeRead
        )

        for (path, entries) in entriesByPath {
            entriesByNormalizedPath[path.normalizedPath] = entries.sortedDeterministically()
            metadataByNormalizedPath[path.normalizedPath] = RemoteMetadata(
                path: path,
                kind: .directory,
                supportsRangeRead: capabilities.supportsByteRangeRead
            )

            for entry in entries {
                metadataByNormalizedPath[entry.path.normalizedPath] = RemoteMetadata(
                    path: entry.path,
                    kind: entry.kind,
                    size: entry.size,
                    modifiedAt: entry.modifiedAt,
                    fileID: entry.fileID,
                    contentType: entry.contentType,
                    supportsRangeRead: capabilities.supportsByteRangeRead
                )
                if entry.kind == .directory {
                    if entriesByNormalizedPath[entry.path.normalizedPath] == nil {
                        entriesByNormalizedPath[entry.path.normalizedPath] = []
                    }
                }
            }
        }

        for (path, data) in fileDataByPath {
            fileDataByNormalizedPath[path.normalizedPath] = data
            metadataByNormalizedPath[path.normalizedPath] = RemoteMetadata(
                path: path,
                kind: .file,
                size: Int64(data.count),
                supportsRangeRead: capabilities.supportsByteRangeRead
            )
        }
    }

    public init(
        rootChildren: [FakeRemoteNode],
        capabilities: RemoteCapabilities = RemoteCapabilities(supportsByteRangeRead: true)
    ) throws {
        self.capabilities = capabilities

        let root = RemotePath(displayPath: "")
        var entriesByNormalizedPath: [String: [RemoteEntry]] = [:]
        var metadataByNormalizedPath: [String: RemoteMetadata] = [
            root.normalizedPath: RemoteMetadata(
                path: root,
                kind: .directory,
                supportsRangeRead: capabilities.supportsByteRangeRead
            )
        ]
        var fileDataByNormalizedPath: [String: Data] = [:]

        try Self.addChildren(
            rootChildren,
            to: root,
            supportsRangeRead: capabilities.supportsByteRangeRead,
            entriesByNormalizedPath: &entriesByNormalizedPath,
            metadataByNormalizedPath: &metadataByNormalizedPath,
            fileDataByNormalizedPath: &fileDataByNormalizedPath
        )

        self.entriesByNormalizedPath = entriesByNormalizedPath
        self.metadataByNormalizedPath = metadataByNormalizedPath
        self.fileDataByNormalizedPath = fileDataByNormalizedPath
        operationErrors = [:]
    }

    public func setError(
        _ error: RemoteFileSystemError,
        for operation: FakeRemoteOperation,
        path: RemotePath
    ) {
        operationErrors[OperationKey(operation: operation, normalizedPath: path.normalizedPath)] = error
    }

    public func list(_ directory: RemotePath) async throws -> [RemoteEntry] {
        try Task.checkCancellation()
        try throwConfiguredError(for: .list, path: directory)

        guard let entries = entriesByNormalizedPath[directory.normalizedPath] else {
            throw RemoteFileSystemError.notFound(directory)
        }

        return entries.sortedDeterministically()
    }

    public func stat(_ path: RemotePath) async throws -> RemoteMetadata {
        try Task.checkCancellation()
        try throwConfiguredError(for: .stat, path: path)

        guard let metadata = metadataByNormalizedPath[path.normalizedPath] else {
            throw RemoteFileSystemError.notFound(path)
        }

        return metadata
    }

    public func read(_ path: RemotePath, range: Range<Int64>) async throws -> Data {
        try Task.checkCancellation()
        try throwConfiguredError(for: .read, path: path)

        guard capabilities.supportsByteRangeRead else {
            throw RemoteFileSystemError.unsupportedRange
        }

        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
            throw RemoteFileSystemError.invalidResponse
        }

        guard let data = fileDataByNormalizedPath[path.normalizedPath] else {
            throw RemoteFileSystemError.notFound(path)
        }

        let lower = min(Int(range.lowerBound), data.count)
        let upper = min(Int(range.upperBound), data.count)
        return data.subdata(in: lower..<upper)
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink?) async throws {
        try Task.checkCancellation()
        try throwConfiguredError(for: .download, path: path)

        guard let data = fileDataByNormalizedPath[path.normalizedPath] else {
            throw RemoteFileSystemError.notFound(path)
        }

        let directoryURL = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let temporaryURL = directoryURL.appendingPathComponent(".\(localURL.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporaryURL, options: .atomic)
            await progress?(TransferProgress(completedBytes: Int64(data.count), totalBytes: Int64(data.count)))
            try Task.checkCancellation()

            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: localURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func addChildren(
        _ children: [FakeRemoteNode],
        to parentPath: RemotePath,
        supportsRangeRead: Bool,
        entriesByNormalizedPath: inout [String: [RemoteEntry]],
        metadataByNormalizedPath: inout [String: RemoteMetadata],
        fileDataByNormalizedPath: inout [String: Data]
    ) throws {
        var entries: [RemoteEntry] = []
        var seenNames = Set<String>()

        for child in children {
            let childPath = parentPath.appending(child.name)
            guard seenNames.insert(childPath.normalizedPath).inserted else {
                throw FakeRemoteFileSystemError.duplicatePath(childPath)
            }

            switch child {
            case .directory(let directory):
                let entry = RemoteEntry(
                    name: directory.name,
                    path: childPath,
                    kind: .directory,
                    modifiedAt: directory.modifiedAt,
                    fileID: directory.fileID
                )
                entries.append(entry)
                metadataByNormalizedPath[childPath.normalizedPath] = RemoteMetadata(
                    path: childPath,
                    kind: .directory,
                    modifiedAt: directory.modifiedAt,
                    fileID: directory.fileID,
                    supportsRangeRead: supportsRangeRead
                )
                try addChildren(
                    directory.children,
                    to: childPath,
                    supportsRangeRead: supportsRangeRead,
                    entriesByNormalizedPath: &entriesByNormalizedPath,
                    metadataByNormalizedPath: &metadataByNormalizedPath,
                    fileDataByNormalizedPath: &fileDataByNormalizedPath
                )

            case .file(let file):
                let entry = RemoteEntry(
                    name: file.name,
                    path: childPath,
                    kind: .file,
                    size: Int64(file.data.count),
                    modifiedAt: file.modifiedAt,
                    contentType: file.contentType,
                    fileID: file.fileID
                )
                entries.append(entry)
                metadataByNormalizedPath[childPath.normalizedPath] = RemoteMetadata(
                    path: childPath,
                    kind: .file,
                    size: Int64(file.data.count),
                    modifiedAt: file.modifiedAt,
                    fileID: file.fileID,
                    contentType: file.contentType,
                    supportsRangeRead: supportsRangeRead
                )
                fileDataByNormalizedPath[childPath.normalizedPath] = file.data
            }
        }

        entriesByNormalizedPath[parentPath.normalizedPath] = entries.sortedDeterministically()
    }

    private func throwConfiguredError(for operation: FakeRemoteOperation, path: RemotePath) throws {
        if let error = operationErrors[OperationKey(operation: operation, normalizedPath: path.normalizedPath)] {
            throw error
        }
    }
}

public enum FakeRemoteOperation: Hashable, Sendable {
    case list
    case stat
    case read
    case download
}

public enum FakeRemoteFileSystemError: Error, Equatable, Sendable {
    case duplicatePath(RemotePath)
}

private struct OperationKey: Hashable, Sendable {
    var operation: FakeRemoteOperation
    var normalizedPath: String
}
