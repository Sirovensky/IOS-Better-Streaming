import Foundation
import EvensongDomain
import RemoteFileSystem
import SMBRemote

public struct SourceConnectionTestResult: Sendable, Equatable {
    public let state: SourceHealthState
    public let capabilities: RemoteCapabilities?
    public let failure: SourceError?
    public let validationIssues: [SourceValidationIssue]
    public let redactedSummary: String
    public let userMessage: String?

    public init(
        state: SourceHealthState,
        capabilities: RemoteCapabilities?,
        failure: SourceError?,
        validationIssues: [SourceValidationIssue] = [],
        redactedSummary: String,
        userMessage: String? = nil
    ) {
        self.state = state
        self.capabilities = capabilities
        self.failure = failure
        self.validationIssues = validationIssues
        self.redactedSummary = redactedSummary
        self.userMessage = userMessage
    }
}

public protocol SourceConnectionTesting: Sendable {
    func testConnection(_ draft: SourceDraft, credential: CredentialSecret?) async -> SourceConnectionTestResult
}

public struct SMBSourceConnectionTester: SourceConnectionTesting {
    public init() {}

    public func testConnection(_ draft: SourceDraft, credential: CredentialSecret?) async -> SourceConnectionTestResult {
        let validation = draft.validationResult
        let configuration = SMBConnectionConfiguration(draft: draft)
        guard validation.isValid else {
            return SourceConnectionTestResult(
                state: .degraded,
                capabilities: nil,
                failure: .unsupportedConfiguration,
                validationIssues: validation.issues,
                redactedSummary: configuration.redactedSummary.description,
                userMessage: SourceValidationError(issues: validation.issues).userMessage
            )
        }

        let authentication = SMBAuthentication(username: draft.username, domain: draft.domain) {
            credential?.password
        }
        let client = SMBRemoteClient(
            configuration: configuration,
            authentication: authentication
        )
        let result = await client.testConnection()
        await client.disconnect()   // one-shot probe: don't leave the session open

        return SourceConnectionTestResult(
            state: result.state.sourceHealthState,
            capabilities: result.capabilities,
            failure: result.failure,
            redactedSummary: result.redactedSummary.description,
            userMessage: result.failure?.userMessage
        )
    }
}

private extension SMBConnectionConfiguration {
    init(draft: SourceDraft) {
        self.init(
            host: draft.endpoint.hostDisplayName,
            port: draft.endpoint.port ?? 445,
            share: draft.endpoint.shareName ?? "",
            username: draft.username,
            domain: draft.domain
        )
    }
}

private extension SMBConnectionTestState {
    var sourceHealthState: SourceHealthState {
        switch self {
        case .online:
            return .online
        case .authenticationFailed:
            return .authFailed
        case .shareNotFound, .hostUnreachable:
            return .unreachable
        case .unsupported:
            return .degraded
        case .cancelled:
            return .unknown
        }
    }
}
