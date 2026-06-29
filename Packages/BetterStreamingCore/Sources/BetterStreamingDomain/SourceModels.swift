import Foundation

public enum SourceProtocolKind: String, Codable, Sendable {
    case smb
    case webDAV
    case ftp
    case sftp
    case nfs
    case dlna
}

public struct SourceEndpoint: Hashable, Codable, Sendable {
    public var hostDisplayName: String
    public var hostFingerprint: String?
    public var port: Int?
    public var shareName: String?

    public init(
        hostDisplayName: String,
        hostFingerprint: String? = nil,
        port: Int? = nil,
        shareName: String? = nil
    ) {
        self.hostDisplayName = hostDisplayName
        self.hostFingerprint = hostFingerprint
        self.port = port
        self.shareName = shareName
    }
}

public struct CredentialRef: Hashable, Codable, Sendable {
    public let keychainService: String
    public let account: String

    public init(keychainService: String, account: String) {
        self.keychainService = keychainService
        self.account = account
    }
}

public struct SourceRoot: Identifiable, Hashable, Codable, Sendable {
    public let id: ShareID
    public var path: RemotePath
    public var mediaKind: RootMediaKind
    public var displayName: String

    public init(
        id: ShareID = ShareID(),
        path: RemotePath,
        mediaKind: RootMediaKind,
        displayName: String
    ) {
        self.id = id
        self.path = path
        self.mediaKind = mediaKind
        self.displayName = displayName
    }
}

public struct SourceRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: SourceID
    public var displayName: String
    public var protocolKind: SourceProtocolKind
    public var endpoint: SourceEndpoint
    public var credentialRef: CredentialRef?
    public var roots: [SourceRoot]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: SourceID = SourceID(),
        displayName: String,
        protocolKind: SourceProtocolKind,
        endpoint: SourceEndpoint,
        credentialRef: CredentialRef? = nil,
        roots: [SourceRoot] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.protocolKind = protocolKind
        self.endpoint = endpoint
        self.credentialRef = credentialRef
        self.roots = roots
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SourceDraft: Sendable, Equatable {
    public var protocolKind: SourceProtocolKind
    public var displayName: String
    public var endpoint: SourceEndpoint
    public var username: String?
    public var domain: String?

    public init(
        protocolKind: SourceProtocolKind,
        displayName: String,
        endpoint: SourceEndpoint,
        username: String? = nil,
        domain: String? = nil
    ) {
        self.protocolKind = protocolKind
        self.displayName = displayName
        self.endpoint = endpoint
        self.username = username
        self.domain = domain
    }
}

public struct CredentialSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let password: String

    public init(password: String) {
        self.password = password
    }

    public func withPassword<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(password)
    }

    public var description: String {
        "<credential-secret:redacted>"
    }

    public var debugDescription: String {
        "<credential-secret:redacted>"
    }
}

public enum SourceHealthState: String, Codable, Sendable {
    case unknown
    case online
    case asleep
    case authFailed
    case localNetworkBlocked
    case unreachable
    case degraded
}

public struct SpeedSample: Hashable, Codable, Sendable {
    public var bytesPerSecond: Double

    public init(bytesPerSecond: Double) {
        self.bytesPerSecond = bytesPerSecond
    }
}

public struct RemoteSourceCapabilities: Hashable, Codable, Sendable {
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

public struct SourceHealthSnapshot: Hashable, Codable, Sendable {
    public var sourceID: SourceID
    public var state: SourceHealthState
    public var lastCheckedAt: Date
    public var speedSample: SpeedSample?
    public var capabilities: RemoteSourceCapabilities?
    public var userMessage: String?

    public init(
        sourceID: SourceID,
        state: SourceHealthState,
        lastCheckedAt: Date = Date(),
        speedSample: SpeedSample? = nil,
        capabilities: RemoteSourceCapabilities? = nil,
        userMessage: String? = nil
    ) {
        self.sourceID = sourceID
        self.state = state
        self.lastCheckedAt = lastCheckedAt
        self.speedSample = speedSample
        self.capabilities = capabilities
        self.userMessage = userMessage
    }
}
