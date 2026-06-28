import Foundation

public protocol RemotePathNormalizer: Sendable {
    func normalize(_ path: String) -> String
}

public struct DefaultRemotePathNormalizer: RemotePathNormalizer {
    public init() {}

    public func normalize(_ path: String) -> String {
        path
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
            .lowercased()
    }
}

public struct SourceID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ShareID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct MediaItemID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct FolderID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct PlaylistID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct QueueID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ScanID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct CacheJobID: Hashable, Codable, Sendable, Identifiable {
    public let rawValue: UUID
    public var id: UUID { rawValue }

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct RemoteFileID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct RemotePath: Hashable, Codable, Sendable {
    public let displayPath: String
    public let normalizedPath: String

    public init(
        displayPath: String,
        normalizedPath: String? = nil,
        normalizer: any RemotePathNormalizer = DefaultRemotePathNormalizer()
    ) {
        self.displayPath = displayPath
        self.normalizedPath = normalizedPath ?? normalizer.normalize(displayPath)
    }

    public func appending(
        _ component: String,
        normalizer: any RemotePathNormalizer = DefaultRemotePathNormalizer()
    ) -> RemotePath {
        let separator = displayPath.hasSuffix("/") || displayPath.isEmpty ? "" : "/"
        return RemotePath(displayPath: "\(displayPath)\(separator)\(component)", normalizer: normalizer)
    }

    public static func == (lhs: RemotePath, rhs: RemotePath) -> Bool {
        lhs.normalizedPath == rhs.normalizedPath
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedPath)
    }
}

public struct RemoteItemIdentity: Hashable, Codable, Sendable {
    public let sourceID: SourceID
    public let shareID: ShareID
    public let path: RemotePath
    public let remoteFileID: RemoteFileID?
    public let size: Int64?
    public let modifiedAt: Date?

    public init(
        sourceID: SourceID,
        shareID: ShareID,
        path: RemotePath,
        remoteFileID: RemoteFileID? = nil,
        size: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.sourceID = sourceID
        self.shareID = shareID
        self.path = path
        self.remoteFileID = remoteFileID
        self.size = size
        self.modifiedAt = modifiedAt
    }

    public var stableKey: String {
        [
            sourceID.rawValue.uuidString.lowercased(),
            shareID.rawValue.uuidString.lowercased(),
            path.normalizedPath,
            remoteFileID?.rawValue ?? "",
            size.map(String.init) ?? "",
            modifiedAt.map { String(Int64(($0.timeIntervalSince1970 * 1_000).rounded(.towardZero))) } ?? ""
        ]
        .map(Self.lengthPrefixed)
        .joined()
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}
