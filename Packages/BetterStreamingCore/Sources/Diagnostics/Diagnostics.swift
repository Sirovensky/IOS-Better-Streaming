import Foundation
import AppFoundation
import BetterStreamingDomain

public typealias DiagnosticRedactor = Redactor

public enum DiagnosticClassification: String, Codable, Sendable, CaseIterable {
    case app
    case connection
    case scan
    case playback
    case filesystem
    case source
    case cache
    case privacy
}

public enum DiagnosticSeverity: String, Codable, Sendable, CaseIterable {
    case info
    case warning
    case error
    case critical
}

public enum DiagnosticEventKind: String, Codable, Sendable, CaseIterable {
    case appState
    case sourceHealth
    case connectionFailure
    case scanFailure
    case playbackFailure
    case privacyRedaction
}

public struct DiagnosticEvent: Sendable, Equatable, Codable {
    public var kind: DiagnosticEventKind
    public var classification: DiagnosticClassification
    public var severity: DiagnosticSeverity
    public var code: String
    public var message: String
    public var metadata: [String: String]

    public init(
        kind: DiagnosticEventKind = .appState,
        classification: DiagnosticClassification = .app,
        severity: DiagnosticSeverity = .info,
        code: String,
        message: String,
        metadata: [String: String] = [:],
        redactor: Redactor = Redactor()
    ) {
        self.kind = kind
        self.classification = classification
        self.severity = severity
        self.code = code
        self.message = redactor.redact(message)
        self.metadata = metadata.reduce(into: [:]) { result, pair in
            result[pair.key] = redactor.redactValue(pair.value, named: pair.key)
        }
    }
}

public protocol DiagnosticsRecording: Sendable {
    func record(_ event: DiagnosticEvent) async
}

public struct DiagnosticErrorSummary: Sendable, Equatable, Codable {
    public var title: String
    public var message: String
    public var recoverySuggestion: String?
    public var diagnosticsCode: String
    public var classification: DiagnosticClassification
    public var severity: DiagnosticSeverity
    public var redactedDebugDescription: String

    public init(
        title: String,
        message: String,
        recoverySuggestion: String? = nil,
        diagnosticsCode: String,
        classification: DiagnosticClassification,
        severity: DiagnosticSeverity = .error,
        redactedDebugDescription: String
    ) {
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.diagnosticsCode = diagnosticsCode
        self.classification = classification
        self.severity = severity
        self.redactedDebugDescription = redactedDebugDescription
    }

    public func diagnosticEvent(
        kind: DiagnosticEventKind? = nil,
        metadata: [String: String] = [:],
        redactor: Redactor = Redactor()
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            kind: kind ?? defaultEventKind,
            classification: classification,
            severity: severity,
            code: diagnosticsCode,
            message: redactedDebugDescription,
            metadata: metadata,
            redactor: redactor
        )
    }

    private var defaultEventKind: DiagnosticEventKind {
        switch classification {
        case .connection, .source:
            return .connectionFailure
        case .scan, .filesystem:
            return .scanFailure
        case .playback:
            return .playbackFailure
        case .app, .cache:
            return .appState
        case .privacy:
            return .privacyRedaction
        }
    }
}

public enum DiagnosticErrorSummaries {
    public static func connection(_ error: any Error, redactor: Redactor = Redactor()) -> DiagnosticErrorSummary {
        if let sourceError = error as? SourceError {
            return connectionSummary(sourceError, redactor: redactor)
        }

        if let remoteError = error as? RemoteFileSystemError {
            return remoteConnectionSummary(remoteError, redactor: redactor)
        }

        return DiagnosticErrorSummary(
            title: "Connection Failed",
            message: "The app could not connect to this source.",
            recoverySuggestion: "Check that the server is awake, reachable, and on the same network.",
            diagnosticsCode: diagnosticCode(for: error, fallback: "connection.failed"),
            classification: .connection,
            redactedDebugDescription: debugDescription(for: error, redactor: redactor)
        )
    }

    public static func scan(_ error: any Error, redactor: Redactor = Redactor()) -> DiagnosticErrorSummary {
        if let remoteError = error as? RemoteFileSystemError {
            return scanSummary(remoteError, redactor: redactor)
        }

        if let sourceError = error as? SourceError {
            return connectionSummary(sourceError, redactor: redactor)
        }

        return DiagnosticErrorSummary(
            title: "Scan Failed",
            message: "The library scan could not continue.",
            recoverySuggestion: "Try again after checking that the source is reachable.",
            diagnosticsCode: diagnosticCode(for: error, fallback: "scan.failed"),
            classification: .scan,
            redactedDebugDescription: debugDescription(for: error, redactor: redactor)
        )
    }

    public static func playback(_ error: any Error, redactor: Redactor = Redactor()) -> DiagnosticErrorSummary {
        if let playbackError = error as? PlaybackError {
            return playbackSummary(playbackError, redactor: redactor)
        }

        if let remoteError = error as? RemoteFileSystemError {
            return playbackRemoteSummary(remoteError, redactor: redactor)
        }

        if let sourceError = error as? SourceError {
            return connectionSummary(sourceError, redactor: redactor)
        }

        return DiagnosticErrorSummary(
            title: "Playback Failed",
            message: "This item could not be played.",
            recoverySuggestion: "Try another item or reconnect the source.",
            diagnosticsCode: diagnosticCode(for: error, fallback: "playback.failed"),
            classification: .playback,
            redactedDebugDescription: debugDescription(for: error, redactor: redactor)
        )
    }

    private static func connectionSummary(_ error: SourceError, redactor: Redactor) -> DiagnosticErrorSummary {
        switch error {
        case .localNetworkDenied:
            return summary(
                title: "Local Network Access Blocked",
                message: "Allow local network access so the app can reach your server.",
                recoverySuggestion: "Open iOS Settings, find the app, and enable Local Network.",
                error: error,
                classification: .connection,
                redactor: redactor
            )
        case .authenticationFailed:
            return summary(
                title: "Sign In Failed",
                message: "The username or password did not work.",
                recoverySuggestion: "Check the saved credentials and try again.",
                error: error,
                classification: .connection,
                redactor: redactor
            )
        case .hostUnreachable:
            return summary(
                title: "Server Not Reachable",
                message: "The server did not respond.",
                recoverySuggestion: "Check Wi-Fi, VPN, and whether the server is awake.",
                error: error,
                classification: .connection,
                redactor: redactor
            )
        case .shareNotFound:
            return summary(
                title: "Share Not Found",
                message: "The selected share could not be found.",
                recoverySuggestion: "Check the share name or choose a different root.",
                error: error,
                classification: .connection,
                redactor: redactor
            )
        case .unsupportedConfiguration:
            return summary(
                title: "Unsupported Server Setup",
                message: "This server configuration is not supported yet.",
                recoverySuggestion: "Try a standard SMB share configuration.",
                error: error,
                classification: .connection,
                redactor: redactor
            )
        case .keychainFailure:
            return summary(
                title: "Credentials Could Not Be Saved",
                message: "The app could not save credentials securely.",
                recoverySuggestion: "Try again after unlocking the device.",
                error: error,
                classification: .source,
                redactor: redactor
            )
        case .cancelled:
            return summary(
                title: "Connection Cancelled",
                message: "The connection attempt was cancelled.",
                recoverySuggestion: nil,
                error: error,
                classification: .connection,
                severity: .info,
                redactor: redactor
            )
        }
    }

    private static func remoteConnectionSummary(_ error: RemoteFileSystemError, redactor: Redactor) -> DiagnosticErrorSummary {
        switch error {
        case .authenticationExpired:
            return summary(
                title: "Sign In Needed",
                message: "The connection needs you to sign in again.",
                recoverySuggestion: "Update the source credentials and retry.",
                error: error,
                classification: .connection,
                redactor: redactor
            )
        case .timeout:
            return summary(
                title: "Connection Timed Out",
                message: "The server took too long to respond.",
                recoverySuggestion: "Check Wi-Fi, VPN, and whether the server is awake.",
                error: error,
                classification: .connection,
                redactor: redactor
            )
        case .serverDisconnected:
            return summary(
                title: "Server Disconnected",
                message: "The server closed the connection.",
                recoverySuggestion: "Reconnect the source and try again.",
                error: error,
                classification: .connection,
                redactor: redactor
            )
        case .cancelled:
            return summary(
                title: "Connection Cancelled",
                message: "The connection attempt was cancelled.",
                recoverySuggestion: nil,
                error: error,
                classification: .connection,
                severity: .info,
                redactor: redactor
            )
        default:
            return summary(
                title: "Connection Failed",
                message: error.userMessage,
                recoverySuggestion: "Check that the server is reachable and try again.",
                error: error,
                classification: .connection,
                redactor: redactor
            )
        }
    }

    private static func scanSummary(_ error: RemoteFileSystemError, redactor: Redactor) -> DiagnosticErrorSummary {
        switch error {
        case .notFound:
            return summary(
                title: "Folder Not Found",
                message: "A folder or file could not be found during the scan.",
                recoverySuggestion: "Refresh the source or repair the moved folder.",
                error: error,
                classification: .scan,
                redactor: redactor
            )
        case .permissionDenied:
            return summary(
                title: "Permission Denied",
                message: "The app cannot read this folder.",
                recoverySuggestion: "Check the server permissions for this account.",
                error: error,
                classification: .scan,
                redactor: redactor
            )
        case .authenticationExpired:
            return summary(
                title: "Sign In Needed",
                message: "The scan needs you to sign in again.",
                recoverySuggestion: "Update the source credentials and retry the scan.",
                error: error,
                classification: .scan,
                redactor: redactor
            )
        case .timeout:
            return summary(
                title: "Scan Timed Out",
                message: "The server took too long to respond during the scan.",
                recoverySuggestion: "Try again when the network is stable.",
                error: error,
                classification: .scan,
                redactor: redactor
            )
        case .serverDisconnected:
            return summary(
                title: "Server Disconnected",
                message: "The server disconnected during the scan.",
                recoverySuggestion: "Reconnect the source and resume scanning.",
                error: error,
                classification: .scan,
                redactor: redactor
            )
        case .cancelled:
            return summary(
                title: "Scan Cancelled",
                message: "The scan was cancelled.",
                recoverySuggestion: nil,
                error: error,
                classification: .scan,
                severity: .info,
                redactor: redactor
            )
        default:
            return summary(
                title: "Scan Failed",
                message: error.userMessage,
                recoverySuggestion: "Try scanning again after checking the source.",
                error: error,
                classification: .scan,
                redactor: redactor
            )
        }
    }

    private static func playbackSummary(_ error: PlaybackError, redactor: Redactor) -> DiagnosticErrorSummary {
        switch error {
        case .sourceUnavailable:
            return summary(
                title: "Source Unavailable",
                message: "The source for this item is not available.",
                recoverySuggestion: "Reconnect the source or play a cached item.",
                error: error,
                classification: .playback,
                redactor: redactor
            )
        case .cacheRequired:
            return summary(
                title: "Cache Required",
                message: "This item needs to be cached before playback.",
                recoverySuggestion: "Download the item and try again.",
                error: error,
                classification: .playback,
                redactor: redactor
            )
        case .unsupportedFormat:
            return summary(
                title: "Unsupported Format",
                message: "This format is not supported by the current player.",
                recoverySuggestion: "Try a different file or a supported format.",
                error: error,
                classification: .playback,
                redactor: redactor
            )
        case .rendererFailed:
            return summary(
                title: "Playback Failed",
                message: "The player could not play this item.",
                recoverySuggestion: "Try again or cache the item first.",
                error: error,
                classification: .playback,
                redactor: redactor
            )
        case .interrupted:
            return summary(
                title: "Playback Interrupted",
                message: "Playback was interrupted.",
                recoverySuggestion: "Press play when you are ready to continue.",
                error: error,
                classification: .playback,
                severity: .warning,
                redactor: redactor
            )
        case .cancelled:
            return summary(
                title: "Playback Cancelled",
                message: "Playback was cancelled.",
                recoverySuggestion: nil,
                error: error,
                classification: .playback,
                severity: .info,
                redactor: redactor
            )
        }
    }

    private static func playbackRemoteSummary(_ error: RemoteFileSystemError, redactor: Redactor) -> DiagnosticErrorSummary {
        switch error {
        case .unsupportedRange:
            return summary(
                title: "Streaming Not Supported",
                message: "This source cannot stream byte ranges.",
                recoverySuggestion: "Cache the item before playing it.",
                error: error,
                classification: .playback,
                redactor: redactor
            )
        case .timeout:
            return summary(
                title: "Playback Timed Out",
                message: "The server took too long to send media data.",
                recoverySuggestion: "Try caching the item or moving closer to Wi-Fi.",
                error: error,
                classification: .playback,
                redactor: redactor
            )
        case .serverDisconnected:
            return summary(
                title: "Server Disconnected",
                message: "The server disconnected during playback.",
                recoverySuggestion: "Reconnect the source or play a cached item.",
                error: error,
                classification: .playback,
                redactor: redactor
            )
        case .authenticationExpired:
            return summary(
                title: "Sign In Needed",
                message: "Playback needs you to sign in again.",
                recoverySuggestion: "Update the source credentials and retry.",
                error: error,
                classification: .playback,
                redactor: redactor
            )
        case .cancelled:
            return summary(
                title: "Playback Cancelled",
                message: "Playback was cancelled.",
                recoverySuggestion: nil,
                error: error,
                classification: .playback,
                severity: .info,
                redactor: redactor
            )
        default:
            return summary(
                title: "Playback Failed",
                message: error.userMessage,
                recoverySuggestion: "Try again or cache the item first.",
                error: error,
                classification: .playback,
                redactor: redactor
            )
        }
    }

    private static func summary(
        title: String,
        message: String,
        recoverySuggestion: String?,
        error: any RedactableError,
        classification: DiagnosticClassification,
        severity: DiagnosticSeverity = .error,
        redactor: Redactor
    ) -> DiagnosticErrorSummary {
        DiagnosticErrorSummary(
            title: title,
            message: redactor.redact(message),
            recoverySuggestion: recoverySuggestion.map(redactor.redact),
            diagnosticsCode: error.diagnosticsCode,
            classification: classification,
            severity: severity,
            redactedDebugDescription: redactor.redact(error.redactedDebugDescription)
        )
    }

    private static func diagnosticCode(for error: any Error, fallback: String) -> String {
        if let redactable = error as? any RedactableError {
            return redactable.diagnosticsCode
        }

        return fallback
    }

    private static func debugDescription(for error: any Error, redactor: Redactor) -> String {
        if let redactable = error as? any RedactableError {
            return redactor.redact(redactable.redactedDebugDescription)
        }

        return redactor.redact(String(describing: error))
    }
}
