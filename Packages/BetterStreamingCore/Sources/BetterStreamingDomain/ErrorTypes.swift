import Foundation

public protocol RedactableError: Error, Sendable {
    var userMessage: String { get }
    var diagnosticsCode: String { get }
    var redactedDebugDescription: String { get }
}

public enum SourceError: RedactableError, Equatable {
    case localNetworkDenied
    case authenticationFailed
    case hostUnreachable
    case shareNotFound
    case unsupportedConfiguration
    case keychainFailure(code: Int32)
    case cancelled

    public var userMessage: String {
        switch self {
        case .localNetworkDenied:
            return "Local network access is blocked."
        case .authenticationFailed:
            return "The username or password did not work."
        case .hostUnreachable:
            return "The server is not reachable."
        case .shareNotFound:
            return "The share could not be found."
        case .unsupportedConfiguration:
            return "This server configuration is not supported yet."
        case .keychainFailure:
            return "Credentials could not be saved securely."
        case .cancelled:
            return "The operation was cancelled."
        }
    }

    public var diagnosticsCode: String {
        switch self {
        case .localNetworkDenied: return "source.local_network_denied"
        case .authenticationFailed: return "source.authentication_failed"
        case .hostUnreachable: return "source.host_unreachable"
        case .shareNotFound: return "source.share_not_found"
        case .unsupportedConfiguration: return "source.unsupported_configuration"
        case .keychainFailure: return "source.keychain_failure"
        case .cancelled: return "source.cancelled"
        }
    }

    public var redactedDebugDescription: String {
        userMessage
    }
}

public enum RemoteFileSystemError: RedactableError, Equatable {
    case notFound(RemotePath)
    case permissionDenied(RemotePath)
    case authenticationExpired
    case timeout
    case serverDisconnected
    case unsupportedRange
    case staleFileHandle
    case invalidResponse
    case cancelled

    public var userMessage: String {
        switch self {
        case .notFound:
            return "The file could not be found."
        case .permissionDenied:
            return "Permission was denied."
        case .authenticationExpired:
            return "The connection needs you to sign in again."
        case .timeout:
            return "The server took too long to respond."
        case .serverDisconnected:
            return "The server disconnected."
        case .unsupportedRange:
            return "This source cannot stream byte ranges."
        case .staleFileHandle:
            return "The file changed while it was being read."
        case .invalidResponse:
            return "The server returned an invalid response."
        case .cancelled:
            return "The operation was cancelled."
        }
    }

    public var diagnosticsCode: String {
        switch self {
        case .notFound: return "rfs.not_found"
        case .permissionDenied: return "rfs.permission_denied"
        case .authenticationExpired: return "rfs.authentication_expired"
        case .timeout: return "rfs.timeout"
        case .serverDisconnected: return "rfs.server_disconnected"
        case .unsupportedRange: return "rfs.unsupported_range"
        case .staleFileHandle: return "rfs.stale_file_handle"
        case .invalidResponse: return "rfs.invalid_response"
        case .cancelled: return "rfs.cancelled"
        }
    }

    public var redactedDebugDescription: String {
        userMessage
    }
}

public enum PlaybackError: RedactableError, Equatable {
    case sourceUnavailable(MediaItemID)
    case cacheRequired(MediaItemID)
    case unsupportedFormat(MediaItemID, reason: String)
    case rendererFailed(MediaItemID, renderer: PlaybackRendererKind, code: String)
    case interrupted
    case cancelled

    public var userMessage: String {
        switch self {
        case .sourceUnavailable:
            return "The source is not available."
        case .cacheRequired:
            return "This item needs to be cached before playback."
        case .unsupportedFormat:
            return "This format is not supported by the current player."
        case .rendererFailed:
            return "Playback failed."
        case .interrupted:
            return "Playback was interrupted."
        case .cancelled:
            return "Playback was cancelled."
        }
    }

    public var diagnosticsCode: String {
        switch self {
        case .sourceUnavailable: return "playback.source_unavailable"
        case .cacheRequired: return "playback.cache_required"
        case .unsupportedFormat: return "playback.unsupported_format"
        case .rendererFailed: return "playback.renderer_failed"
        case .interrupted: return "playback.interrupted"
        case .cancelled: return "playback.cancelled"
        }
    }

    public var redactedDebugDescription: String {
        userMessage
    }
}
