import Foundation
import BetterStreamingDomain
import RemoteFileSystem

public enum SourceProtocolKind: String, Codable, Sendable, Equatable {
    case smb
    case webDAV
    case ftp
    case sftp
    case nfs
    case dlna
}

public struct SourceEndpoint: Codable, Sendable, Equatable {
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

    public var redactedSummary: CredentialReferenceSummary {
        CredentialReferenceSummary(
            service: RedactedSourceValue.stableLabel(prefix: "service", value: keychainService),
            account: RedactedSourceValue.stableLabel(prefix: "account", value: account)
        )
    }
}

extension CredentialRef: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        redactedSummary.description
    }

    public var debugDescription: String {
        redactedSummary.description
    }
}

public struct CredentialReferenceSummary: Hashable, Codable, Sendable, CustomStringConvertible {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public var description: String {
        "CredentialRef(service: \(service), account: \(account))"
    }
}

public protocol CredentialResolving: Sendable {
    func credentialSecret(for reference: CredentialRef) async throws -> CredentialSecret
}

public protocol CredentialReferenceStoring: Sendable {
    func storeCredential(_ credential: CredentialSecret, account: String) async throws -> CredentialRef
    func updateCredential(_ credential: CredentialSecret, for reference: CredentialRef) async throws
    func deleteCredential(for reference: CredentialRef) async throws
}

public struct SourceRoot: Identifiable, Codable, Sendable, Equatable {
    public let id: ShareID
    public var path: RemotePath
    public var mediaKind: RootMediaKind
    public var displayName: String

    public init(id: ShareID = ShareID(), path: RemotePath, mediaKind: RootMediaKind, displayName: String) {
        self.id = id
        self.path = path
        self.mediaKind = mediaKind
        self.displayName = displayName
    }
}

public struct SourceRecord: Identifiable, Codable, Sendable, Equatable {
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

    public var redactedSummary: SourceRedactedSummary {
        SourceRedactedSummary(source: self)
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

    public var validationResult: SourceValidationResult {
        SourceValidator().validate(self)
    }

    public func validate() throws {
        try validationResult.throwIfInvalid()
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

public enum SourceHealthState: String, Codable, Sendable, Equatable {
    case unknown
    case online
    case asleep
    case authFailed
    case localNetworkBlocked
    case unreachable
    case degraded
}

public struct SpeedSample: Codable, Sendable, Equatable {
    public var bytesPerSecond: Double

    public init(bytesPerSecond: Double) {
        self.bytesPerSecond = bytesPerSecond
    }
}

public struct SourceHealthSnapshot: Codable, Sendable, Equatable {
    public var sourceID: SourceID
    public var state: SourceHealthState
    public var lastCheckedAt: Date
    public var speedSample: SpeedSample?
    public var capabilities: RemoteCapabilities?
    public var userMessage: String?

    public init(
        sourceID: SourceID,
        state: SourceHealthState,
        lastCheckedAt: Date = Date(),
        speedSample: SpeedSample? = nil,
        capabilities: RemoteCapabilities? = nil,
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

public struct SourceRedactedSummary: Hashable, Codable, Sendable, CustomStringConvertible {
    public let id: SourceID
    public let displayName: String
    public let protocolKind: SourceProtocolKind
    public let host: String
    public let port: Int?
    public let share: String?
    public let hasCredential: Bool
    public let credential: CredentialReferenceSummary?
    public let rootCount: Int

    public init(source: SourceRecord) {
        id = source.id
        displayName = source.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        protocolKind = source.protocolKind
        host = RedactedSourceValue.stableLabel(prefix: "host", value: source.endpoint.hostDisplayName)
        port = source.endpoint.port
        share = source.endpoint.shareName.map { RedactedSourceValue.stableLabel(prefix: "share", value: $0) }
        hasCredential = source.credentialRef != nil
        credential = source.credentialRef?.redactedSummary
        rootCount = source.roots.count
    }

    public var description: String {
        "Source(id: \(id.rawValue), name: \(displayName), protocol: \(protocolKind.rawValue), host: \(host), port: \(port.map(String.init) ?? "<default>"), share: \(share ?? "<none>"), credential: \(hasCredential ? "<present>" : "<none>"), roots: \(rootCount))"
    }
}

public enum SourceValidationIssue: Hashable, Codable, Sendable {
    case missingDisplayName
    case unsupportedProtocol(SourceProtocolKind)
    case missingHost
    case invalidPort
    case missingShare
    case shareContainsPathSeparator
    case blankUsername
    case blankDomain

    public var diagnosticsCode: String {
        switch self {
        case .missingDisplayName:
            return "source.validation.missing_display_name"
        case .unsupportedProtocol:
            return "source.validation.unsupported_protocol"
        case .missingHost:
            return "source.validation.missing_host"
        case .invalidPort:
            return "source.validation.invalid_port"
        case .missingShare:
            return "source.validation.missing_share"
        case .shareContainsPathSeparator:
            return "source.validation.share_contains_path_separator"
        case .blankUsername:
            return "source.validation.blank_username"
        case .blankDomain:
            return "source.validation.blank_domain"
        }
    }
}

public struct SourceValidationResult: Sendable, Equatable {
    public let issues: [SourceValidationIssue]

    public init(issues: [SourceValidationIssue]) {
        self.issues = issues
    }

    public var isValid: Bool {
        issues.isEmpty
    }

    public func throwIfInvalid() throws {
        guard isValid else {
            throw SourceValidationError(issues: issues)
        }
    }
}

public struct SourceValidationError: RedactableError, Equatable {
    public let issues: [SourceValidationIssue]

    public init(issues: [SourceValidationIssue]) {
        self.issues = issues
    }

    public var userMessage: String {
        "The source details are incomplete."
    }

    public var diagnosticsCode: String {
        "source.validation_failed"
    }

    public var redactedDebugDescription: String {
        "Source validation failed: \(issues.map(\.diagnosticsCode).joined(separator: ","))"
    }
}

public struct SourceValidator: Sendable {
    public init() {}

    public func validate(_ draft: SourceDraft) -> SourceValidationResult {
        var issues: [SourceValidationIssue] = []

        if draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingDisplayName)
        }

        switch draft.protocolKind {
        case .smb:
            issues.append(contentsOf: validateSMBEndpoint(draft.endpoint))
        case .webDAV, .ftp, .sftp, .nfs, .dlna:
            issues.append(.unsupportedProtocol(draft.protocolKind))
        }

        if let username = draft.username, username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.blankUsername)
        }
        if let domain = draft.domain, domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.blankDomain)
        }

        return SourceValidationResult(issues: issues)
    }

    private func validateSMBEndpoint(_ endpoint: SourceEndpoint) -> [SourceValidationIssue] {
        var issues: [SourceValidationIssue] = []
        if endpoint.hostDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingHost)
        }
        if let port = endpoint.port, !(1...65_535).contains(port) {
            issues.append(.invalidPort)
        }

        let shareName = endpoint.shareName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if shareName.isEmpty {
            issues.append(.missingShare)
        } else if shareName.contains("/") || shareName.contains("\\") {
            issues.append(.shareContainsPathSeparator)
        }
        return issues
    }
}

private enum RedactedSourceValue {
    static func stableLabel(prefix: String, value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "<\(prefix):empty>"
        }
        return "<\(prefix):\(fnv1a64(trimmed))>"
    }

    private static func fnv1a64(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
