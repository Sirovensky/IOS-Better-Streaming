import Foundation
import BetterStreamingDomain

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

public extension CredentialRef {
    var redactedSummary: CredentialReferenceSummary {
        CredentialReferenceSummary(
            service: RedactedSourceValue.stableLabel(prefix: "service", value: keychainService),
            account: RedactedSourceValue.stableLabel(prefix: "account", value: account)
        )
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

public extension SourceRecord {
    var redactedSummary: SourceRedactedSummary {
        SourceRedactedSummary(source: self)
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
        case .webDAV, .ftp, .sftp:
            issues.append(contentsOf: validateHostPortEndpoint(draft.endpoint))
        case .nfs, .dlna:
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

    /// WebDAV/FTP/SFTP: require a host and a valid port. Unlike SMB there is no
    /// mandatory share — WebDAV uses a URL path and FTP/SFTP a base path, both
    /// optional — so only host + port are checked.
    private func validateHostPortEndpoint(_ endpoint: SourceEndpoint) -> [SourceValidationIssue] {
        var issues: [SourceValidationIssue] = []
        if endpoint.hostDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingHost)
        }
        if let port = endpoint.port, !(1...65_535).contains(port) {
            issues.append(.invalidPort)
        }
        return issues
    }
}

public extension SourceDraft {
    var validationResult: SourceValidationResult {
        SourceValidator().validate(self)
    }

    func validate() throws {
        try validationResult.throwIfInvalid()
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
