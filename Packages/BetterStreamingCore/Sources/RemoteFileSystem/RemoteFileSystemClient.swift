import Foundation
import BetterStreamingDomain

public struct RemoteCapabilities: Codable, Sendable, Equatable {
    public var supportsByteRangeRead: Bool
    public var supportsServerSideSearch: Bool
    public var supportsStableFileID: Bool
    public var supportsDirectoryModifiedTime: Bool
    public var supportsBackgroundURLSession: Bool

    public init(
        supportsByteRangeRead: Bool,
        supportsServerSideSearch: Bool = false,
        supportsStableFileID: Bool = false,
        supportsDirectoryModifiedTime: Bool = true,
        supportsBackgroundURLSession: Bool = false
    ) {
        self.supportsByteRangeRead = supportsByteRangeRead
        self.supportsServerSideSearch = supportsServerSideSearch
        self.supportsStableFileID = supportsStableFileID
        self.supportsDirectoryModifiedTime = supportsDirectoryModifiedTime
        self.supportsBackgroundURLSession = supportsBackgroundURLSession
    }
}

public enum RemoteEntryKind: String, Codable, Sendable {
    case file
    case directory
    case symbolicLink
    case unknown
}

public struct RemoteEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: RemotePath { path }
    public let name: String
    public let path: RemotePath
    public let kind: RemoteEntryKind
    public let size: Int64?
    public let modifiedAt: Date?
    public let contentType: String?
    public let fileID: RemoteFileID?

    public init(
        name: String,
        path: RemotePath,
        kind: RemoteEntryKind,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        contentType: String? = nil,
        fileID: RemoteFileID? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.contentType = contentType
        self.fileID = fileID
    }
}

public struct RemoteMetadata: Hashable, Codable, Sendable {
    public let path: RemotePath
    public let kind: RemoteEntryKind
    public let size: Int64?
    public let modifiedAt: Date?
    public let fileID: RemoteFileID?
    public let contentType: String?
    public let supportsRangeRead: Bool

    public init(
        path: RemotePath,
        kind: RemoteEntryKind,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        fileID: RemoteFileID? = nil,
        contentType: String? = nil,
        supportsRangeRead: Bool = true
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.fileID = fileID
        self.contentType = contentType
        self.supportsRangeRead = supportsRangeRead
    }
}

public struct TransferProgress: Sendable, Equatable {
    public let completedBytes: Int64
    public let totalBytes: Int64?

    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

public typealias ProgressSink = @Sendable (TransferProgress) async -> Void

public protocol RemoteFileSystemClient: Sendable {
    var capabilities: RemoteCapabilities { get }

    func list(_ directory: RemotePath) async throws -> [RemoteEntry]
    func stat(_ path: RemotePath) async throws -> RemoteMetadata
    func read(_ path: RemotePath, range: Range<Int64>) async throws -> Data
    func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink?) async throws
    /// Tear down any cached connection without blocking, so the underlying
    /// session is released back to the server. Idempotent; the client lazily
    /// reconnects on the next operation. Default no-op for stateless clients.
    func disconnect() async
}

public extension RemoteFileSystemClient {
    func disconnect() async {}
}

public extension RemotePath {
    var remotePathComponents: [String] {
        displayPath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    var lastPathComponent: String {
        remotePathComponents.last ?? ""
    }

    var parentPath: RemotePath? {
        let components = remotePathComponents
        guard !components.isEmpty else {
            return nil
        }

        return RemotePath(displayPath: components.dropLast().joined(separator: "/"))
    }
}

public extension Sequence where Element == RemoteEntry {
    func sortedDeterministically() -> [RemoteEntry] {
        sorted { lhs, rhs in
            RemoteEntrySort.areInIncreasingOrder(lhs, rhs)
        }
    }
}

public enum RemoteEntrySort {
    public static func sortKey(for name: String) -> String {
        tokenize(name)
            .map { token in
                switch token {
                case .number(let value):
                    return "0\(value.count):\(value)"
                case .text(let value):
                    return "1\(value)"
                }
            }
            .joined(separator: "\u{1f}")
    }

    public static func areInIncreasingOrder(_ lhs: RemoteEntry, _ rhs: RemoteEntry) -> Bool {
        let lhsKind = kindRank(lhs.kind)
        let rhsKind = kindRank(rhs.kind)

        if lhsKind != rhsKind {
            return lhsKind < rhsKind
        }

        let lhsTokens = tokenize(lhs.name)
        let rhsTokens = tokenize(rhs.name)

        for index in 0..<min(lhsTokens.count, rhsTokens.count) {
            switch (lhsTokens[index], rhsTokens[index]) {
            case (.number(let lhsNumber), .number(let rhsNumber)):
                if lhsNumber.count != rhsNumber.count {
                    return lhsNumber.count < rhsNumber.count
                }
                if lhsNumber != rhsNumber {
                    return lhsNumber < rhsNumber
                }
            case (.number, .text):
                return true
            case (.text, .number):
                return false
            case (.text(let lhsText), .text(let rhsText)):
                if lhsText != rhsText {
                    return lhsText < rhsText
                }
            }
        }

        if lhsTokens.count != rhsTokens.count {
            return lhsTokens.count < rhsTokens.count
        }

        return lhs.name < rhs.name
    }

    private static func kindRank(_ kind: RemoteEntryKind) -> Int {
        switch kind {
        case .directory:
            return 0
        case .file:
            return 1
        case .symbolicLink:
            return 2
        case .unknown:
            return 3
        }
    }

    private static func tokenize(_ value: String) -> [SortToken] {
        var result: [SortToken] = []
        var current = ""
        var currentIsNumber: Bool?

        for scalar in value.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars {
            let isNumber = CharacterSet.decimalDigits.contains(scalar)
            if let currentIsNumber, currentIsNumber != isNumber {
                result.append(.make(current, isNumber: currentIsNumber))
                current.removeAll(keepingCapacity: true)
            }

            current.append(String(scalar))
            currentIsNumber = isNumber
        }

        if let currentIsNumber, !current.isEmpty {
            result.append(.make(current, isNumber: currentIsNumber))
        }

        return result
    }

    private enum SortToken {
        case number(String)
        case text(String)

        static func make(_ value: String, isNumber: Bool) -> SortToken {
            if isNumber {
                let trimmed = value.drop { $0 == "0" }
                return .number(trimmed.isEmpty ? "0" : String(trimmed))
            }

            return .text(value)
        }
    }
}
