import Foundation
import BetterStreamingDomain
import RemoteFileSystem
import SMBClient

public struct SMBConnectionConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var host: String
    public var port: Int
    public var share: String
    public var username: String?
    public var domain: String?

    public init(
        host: String,
        port: Int = 445,
        share: String,
        username: String? = nil,
        domain: String? = nil
    ) {
        self.host = host
        self.port = port
        self.share = share
        self.username = username
        self.domain = domain
    }

    public var redactedSummary: SMBConnectionRedactedSummary {
        SMBConnectionRedactedSummary(
            host: RedactedValue.stableLabel(prefix: "host", value: host),
            port: port,
            share: RedactedValue.stableLabel(prefix: "share", value: share),
            hasUsername: username?.isEmpty == false,
            hasDomain: domain?.isEmpty == false
        )
    }

    public var validationIssues: [SMBConnectionValidationIssue] {
        var issues: [SMBConnectionValidationIssue] = []
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingHost)
        }
        if !(1...65_535).contains(port) {
            issues.append(.invalidPort)
        }
        let trimmedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedShare.isEmpty {
            issues.append(.missingShare)
        } else if trimmedShare.contains("/") || trimmedShare.contains("\\") {
            issues.append(.shareContainsPathSeparator)
        }
        return issues
    }

    public func validate() throws {
        let issues = validationIssues
        guard issues.isEmpty else {
            throw SMBConnectionValidationError(issues: issues)
        }
    }

    public var description: String {
        redactedSummary.description
    }

    public var debugDescription: String {
        redactedSummary.description
    }
}

public struct SMBConnectionRedactedSummary: Sendable, Equatable, CustomStringConvertible {
    public let host: String
    public let port: Int
    public let share: String
    public let hasUsername: Bool
    public let hasDomain: Bool

    public init(host: String, port: Int, share: String, hasUsername: Bool, hasDomain: Bool) {
        self.host = host
        self.port = port
        self.share = share
        self.hasUsername = hasUsername
        self.hasDomain = hasDomain
    }

    public var description: String {
        "SMBConnection(host: \(host), port: \(port), share: \(share), username: \(hasUsername ? "<redacted>" : "<none>"), domain: \(hasDomain ? "<redacted>" : "<none>"))"
    }
}

public enum SMBConnectionValidationIssue: String, Codable, Sendable, Equatable {
    case missingHost
    case invalidPort
    case missingShare
    case shareContainsPathSeparator
}

public struct SMBConnectionValidationError: RedactableError, Equatable {
    public let issues: [SMBConnectionValidationIssue]

    public init(issues: [SMBConnectionValidationIssue]) {
        self.issues = issues
    }

    public var userMessage: String {
        "The SMB connection details are incomplete."
    }

    public var diagnosticsCode: String {
        "smb.validation_failed"
    }

    public var redactedDebugDescription: String {
        "SMB validation failed: \(issues.map(\.rawValue).joined(separator: ","))"
    }
}

public struct SMBAuthentication: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let username: String?
    public let domain: String?
    private let passwordProvider: @Sendable () async throws -> String?

    public init(
        username: String? = nil,
        domain: String? = nil,
        passwordProvider: @escaping @Sendable () async throws -> String? = { nil }
    ) {
        self.username = Self.nonBlank(username)
        self.domain = Self.nonBlank(domain)
        self.passwordProvider = passwordProvider
    }

    public static let anonymous = SMBAuthentication()

    public static func password(
        username: String?,
        domain: String? = nil,
        password: String
    ) -> SMBAuthentication {
        SMBAuthentication(username: username, domain: domain) {
            password
        }
    }

    public var redactedSummary: SMBAuthenticationRedactedSummary {
        SMBAuthenticationRedactedSummary(
            hasUsername: username?.isEmpty == false,
            hasDomain: domain?.isEmpty == false
        )
    }

    public var description: String {
        redactedSummary.description
    }

    public var debugDescription: String {
        redactedSummary.description
    }

    func resolvePassword() async throws -> String? {
        try await Self.nonBlank(passwordProvider())
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

public struct SMBAuthenticationRedactedSummary: Sendable, Equatable, CustomStringConvertible {
    public let hasUsername: Bool
    public let hasDomain: Bool

    public init(hasUsername: Bool, hasDomain: Bool) {
        self.hasUsername = hasUsername
        self.hasDomain = hasDomain
    }

    public var description: String {
        "SMBAuthentication(username: \(hasUsername ? "<redacted>" : "<anonymous>"), domain: \(hasDomain ? "<redacted>" : "<none>"), password: <redacted>)"
    }
}

public enum SMBRemoteItemKind: String, Sendable, Equatable {
    case file
    case directory
}

public struct SMBRemoteItem: Sendable, Equatable {
    public let name: String
    public let kind: SMBRemoteItemKind
    public let size: Int64?
    public let modifiedAt: Date?

    public init(name: String, kind: SMBRemoteItemKind, size: Int64? = nil, modifiedAt: Date? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct SMBRemoteMetadata: Sendable, Equatable {
    public let kind: SMBRemoteItemKind
    public let size: Int64?
    public let modifiedAt: Date?
    public let fileID: RemoteFileID?

    public init(kind: SMBRemoteItemKind, size: Int64? = nil, modifiedAt: Date? = nil, fileID: RemoteFileID? = nil) {
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.fileID = fileID
    }
}

public protocol SMBRemoteTransport: Sendable {
    func listDirectory(path: String) async throws -> [SMBRemoteItem]
    func metadata(path: String) async throws -> SMBRemoteMetadata
    func read(path: String, offset: Int64, length: Int64) async throws -> Data
    func download(path: String, to localURL: URL, progress: ProgressSink?) async throws
}

public typealias SMBRemoteTransportFactory = @Sendable (
    _ configuration: SMBConnectionConfiguration,
    _ authentication: SMBAuthentication
) async throws -> any SMBRemoteTransport

public enum SMBConnectionTestState: String, Sendable, Equatable {
    case online
    case authenticationFailed
    case shareNotFound
    case hostUnreachable
    case unsupported
    case cancelled
}

public struct SMBConnectionTestResult: Sendable, Equatable {
    public let state: SMBConnectionTestState
    public let capabilities: RemoteCapabilities?
    public let failure: SourceError?
    public let redactedSummary: SMBConnectionRedactedSummary

    public init(
        state: SMBConnectionTestState,
        capabilities: RemoteCapabilities?,
        failure: SourceError?,
        redactedSummary: SMBConnectionRedactedSummary
    ) {
        self.state = state
        self.capabilities = capabilities
        self.failure = failure
        self.redactedSummary = redactedSummary
    }
}

public actor SMBRemoteClient: RemoteFileSystemClient {
    public nonisolated let configuration: SMBConnectionConfiguration
    public nonisolated let capabilities = RemoteCapabilities(supportsByteRangeRead: true)

    private let authentication: SMBAuthentication
    private let transportFactory: SMBRemoteTransportFactory
    private var transport: (any SMBRemoteTransport)?

    public init(
        configuration: SMBConnectionConfiguration,
        authentication: SMBAuthentication? = nil,
        transportFactory: SMBRemoteTransportFactory? = nil
    ) {
        self.configuration = configuration
        self.authentication = authentication ?? SMBAuthentication(
            username: configuration.username,
            domain: configuration.domain
        )
        self.transportFactory = transportFactory ?? LiveSMBRemoteTransport.make
    }

    public func list(_ directory: RemotePath) async throws -> [RemoteEntry] {
        do {
            let transport = try await activeTransport()
            let smbPath = SMBPathFormatter.smbPath(from: directory)
            return try await transport.listDirectory(path: smbPath)
                .filter { $0.name != "." && $0.name != ".." }
                .map { item in
                    let entryPath = directory.appending(item.name)
                    return RemoteEntry(
                        name: item.name,
                        path: entryPath,
                        kind: item.kind.remoteEntryKind,
                        size: item.kind == .file ? item.size : nil,
                        modifiedAt: item.modifiedAt
                    )
                }
        } catch {
            try handleFailure(error, path: directory)
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteMetadata {
        do {
            let transport = try await activeTransport()
            let metadata = try await transport.metadata(path: SMBPathFormatter.smbPath(from: path))
            return RemoteMetadata(
                path: path,
                kind: metadata.kind.remoteEntryKind,
                size: metadata.kind == .file ? metadata.size : nil,
                modifiedAt: metadata.modifiedAt,
                fileID: metadata.fileID
            )
        } catch {
            try handleFailure(error, path: path)
        }
    }

    public func read(_ path: RemotePath, range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
            throw RemoteFileSystemError.unsupportedRange
        }
        let length = range.upperBound - range.lowerBound
        guard length <= Int64(UInt32.max) else {
            throw RemoteFileSystemError.unsupportedRange
        }
        guard length > 0 else {
            return Data()
        }
        do {
            let transport = try await activeTransport()
            return try await transport.read(
                path: SMBPathFormatter.smbPath(from: path),
                offset: range.lowerBound,
                length: length
            )
        } catch {
            try handleFailure(error, path: path)
        }
    }

    /// Map a thrown SMB error and, when it indicates the connection itself died,
    /// drop the cached transport so the NEXT operation reconnects on a fresh one.
    /// This recovers without ever abandoning an in-flight NWConnection operation
    /// (abandoning corrupts the connection's receive buffer → an `EXC_BREAKPOINT`
    /// in `ByteReader` — and leaves the send semaphore locked → permanent hang).
    private func handleFailure(_ error: Error, path: RemotePath) throws -> Never {
        let mapped = Self.remoteFileSystemError(from: error, path: path)
        if let rfs = mapped as? RemoteFileSystemError {
            switch rfs {
            case .serverDisconnected, .timeout, .invalidResponse:
                transport = nil
            default:
                break
            }
        }
        throw mapped
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink?) async throws {
        do {
            let transport = try await activeTransport()
            try await transport.download(
                path: SMBPathFormatter.smbPath(from: path),
                to: localURL,
                progress: progress
            )
        } catch {
            throw Self.remoteFileSystemError(from: error, path: path)
        }
    }

    public func testConnection() async -> SMBConnectionTestResult {
        do {
            try configuration.validate()
            let transport = try await activeTransport()
            _ = try await transport.listDirectory(path: "")
            return SMBConnectionTestResult(
                state: .online,
                capabilities: capabilities,
                failure: nil,
                redactedSummary: configuration.redactedSummary
            )
        } catch {
            let failure = Self.sourceError(from: error)
            return SMBConnectionTestResult(
                state: Self.connectionState(for: failure),
                capabilities: nil,
                failure: failure,
                redactedSummary: configuration.redactedSummary
            )
        }
    }

    private func activeTransport() async throws -> any SMBRemoteTransport {
        if let transport {
            return transport
        }
        try configuration.validate()
        let newTransport = try await transportFactory(configuration, authentication)
        transport = newTransport
        return newTransport
    }

    private static func connectionState(for sourceError: SourceError) -> SMBConnectionTestState {
        switch sourceError {
        case .authenticationFailed:
            return .authenticationFailed
        case .shareNotFound:
            return .shareNotFound
        case .hostUnreachable, .localNetworkDenied:
            return .hostUnreachable
        case .cancelled:
            return .cancelled
        case .unsupportedConfiguration, .keychainFailure:
            return .unsupported
        }
    }

    private static func sourceError(from error: Error) -> SourceError {
        if let error = error as? SourceError {
            return error
        }
        if error is CancellationError {
            return .cancelled
        }
        if let validationError = error as? SMBConnectionValidationError, !validationError.issues.isEmpty {
            return .unsupportedConfiguration
        }
        if let error = error as? ErrorResponse {
            let status = NTStatus(error.header.status)
            if status == .logonFailure || status == .accessDenied {
                return .authenticationFailed
            }
            if status == .badNetworkName || status == .objectNameNotFound || status == .objectPathNotFound {
                return .shareNotFound
            }
            if status == .ioTimeout || status == .connectionRefused || status == .networkNameDeleted {
                return .hostUnreachable
            }
        }
        if let error = error as? ConnectionError {
            switch error {
            case .cancelled:
                return .cancelled
            case .disconnected, .noData, .unknown:
                return .hostUnreachable
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut:
                return .hostUnreachable
            default:
                break
            }
        }
        return .unsupportedConfiguration
    }

    private static func remoteFileSystemError(from error: Error, path: RemotePath) -> Error {
        if let error = error as? RemoteFileSystemError {
            return error
        }
        if error is CancellationError {
            return RemoteFileSystemError.cancelled
        }
        if let error = error as? ErrorResponse {
            let status = NTStatus(error.header.status)
            if status == .objectNameNotFound || status == .objectPathNotFound || status == .badNetworkName {
                return RemoteFileSystemError.notFound(path)
            }
            if status == .logonFailure || status == .networkSessionExpired || status == .userSessionDeleted {
                return RemoteFileSystemError.authenticationExpired
            }
            if status == .accessDenied {
                return RemoteFileSystemError.permissionDenied(path)
            }
            if status == .ioTimeout {
                return RemoteFileSystemError.timeout
            }
            if status == .networkNameDeleted || status == .fileClosed {
                return RemoteFileSystemError.serverDisconnected
            }
            if status == .notSupported || status == .invalidParameter {
                return RemoteFileSystemError.unsupportedRange
            }
        }
        if let error = error as? ConnectionError {
            switch error {
            case .cancelled:
                return RemoteFileSystemError.cancelled
            case .disconnected, .noData:
                return RemoteFileSystemError.serverDisconnected
            case .unknown:
                return RemoteFileSystemError.invalidResponse
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled:
                return RemoteFileSystemError.cancelled
            case .timedOut:
                return RemoteFileSystemError.timeout
            case .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet:
                return RemoteFileSystemError.serverDisconnected
            default:
                break
            }
        }
        return RemoteFileSystemError.invalidResponse
    }
}

private final class LiveSMBRemoteTransport: @unchecked Sendable, SMBRemoteTransport {
    private let client: SMBClient
    /// Open `FileReader`s pooled by path. The SMB connection serves one request
    /// at a time (a single mutex), so reopening a reader on every ranged read —
    /// CREATE + READ + CLOSE = three serialized round-trips per chunk — throttles
    /// streaming and lets a long fill loop starve a concurrent seek. Reusing an
    /// open reader collapses that to one READ round-trip per chunk. `FileReader`
    /// is not `Sendable`, so the pool is guarded by a lock (never held across an
    /// await) and every reader is closed inline, never captured into a `Task`.
    private let poolLock = NSLock()
    private var readers: [String: FileReader] = [:]
    private var readerOrder: [String] = []
    private static let maxPooledReaders = 4

    private init(client: SMBClient) {
        self.client = client
    }

    static func make(
        configuration: SMBConnectionConfiguration,
        authentication: SMBAuthentication
    ) async throws -> any SMBRemoteTransport {
        let client = SMBClient(host: configuration.host, port: configuration.port)
        try await client.login(
            username: authentication.username,
            password: try await authentication.resolvePassword(),
            domain: authentication.domain
        )
        try await client.connectShare(configuration.share)
        return LiveSMBRemoteTransport(client: client)
    }

    func listDirectory(path: String) async throws -> [SMBRemoteItem] {
        try await client.listDirectory(path: path).map { file in
            SMBRemoteItem(
                name: file.name,
                kind: file.isDirectory ? .directory : .file,
                size: file.isDirectory ? nil : Int64.clamping(file.size),
                modifiedAt: file.lastWriteTime
            )
        }
    }

    func metadata(path: String) async throws -> SMBRemoteMetadata {
        let stat = try await client.fileStat(path: path)
        return SMBRemoteMetadata(
            kind: stat.isDirectory ? .directory : .file,
            size: stat.isDirectory ? nil : Int64.clamping(stat.size),
            modifiedAt: stat.lastWriteTime
        )
    }

    func read(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard offset >= 0, length >= 0, length <= Int64(UInt32.max) else {
            throw RemoteFileSystemError.unsupportedRange
        }
        do {
            return try await pooledRead(path: path, offset: offset, length: length)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The pooled handle may be stale (server idle-closed it, or the
            // session reconnected). `pooledRead` already dropped it; retry once
            // with a fresh open before surfacing the failure, so pooling is never
            // less reliable than opening per-read.
            return try await pooledRead(path: path, offset: offset, length: length)
        }
    }

    /// Read through the pooled reader for `path`. On any failure the pooled entry
    /// is dropped (never leaving a stale handle cached) and the error rethrown
    /// for the caller to retry or surface.
    private func pooledRead(path: String, offset: Int64, length: Int64) async throws -> Data {
        let reader = try await reader(for: path)
        do {
            return try await reader.read(offset: UInt64(offset), length: UInt32(length))
        } catch {
            if let dropped = dropReader(path: path, ifSameAs: reader) {
                try? await dropped.close()
            }
            throw error
        }
    }

    /// Return the pooled reader for `path`, opening (and pooling) one if needed.
    /// Opening forces the lazy SMB CREATE so open errors surface here, not later.
    private func reader(for path: String) async throws -> FileReader {
        if let existing = cachedReader(path: path) { return existing }
        let reader = client.fileReader(path: path)
        _ = try await reader.fileSize   // force the lazy CREATE once
        let stored = storeReader(reader, path: path)
        if let loser = stored.loser { try? await loser.close() }
        for evicted in stored.evicted { try? await evicted.close() }
        return stored.winner
    }

    private func cachedReader(path: String) -> FileReader? {
        poolLock.lock(); defer { poolLock.unlock() }
        guard let reader = readers[path] else { return nil }
        touchLocked(path)
        return reader
    }

    /// Insert a freshly-opened reader. If another read opened one for the same
    /// path concurrently, keep the incumbent and hand ours back as `loser` to be
    /// closed. Returns any readers evicted to stay within the pool cap.
    private func storeReader(
        _ reader: FileReader,
        path: String
    ) -> (winner: FileReader, loser: FileReader?, evicted: [FileReader]) {
        poolLock.lock(); defer { poolLock.unlock() }
        if let existing = readers[path] {
            touchLocked(path)
            return (existing, reader, [])
        }
        readers[path] = reader
        touchLocked(path)
        var evicted: [FileReader] = []
        while readerOrder.count > Self.maxPooledReaders {
            let stale = readerOrder.removeFirst()
            if let r = readers.removeValue(forKey: stale) { evicted.append(r) }
        }
        return (reader, nil, evicted)
    }

    /// Drop the pooled reader for `path` only if it is still the failing one (a
    /// concurrent retry may have already replaced it). Returns it for closing.
    private func dropReader(path: String, ifSameAs reader: FileReader) -> FileReader? {
        poolLock.lock(); defer { poolLock.unlock() }
        guard let current = readers[path], current === reader else { return nil }
        readers.removeValue(forKey: path)
        if let idx = readerOrder.firstIndex(of: path) { readerOrder.remove(at: idx) }
        return current
    }

    private func touchLocked(_ path: String) {
        if let idx = readerOrder.firstIndex(of: path) { readerOrder.remove(at: idx) }
        readerOrder.append(path)
    }

    func download(path: String, to localURL: URL, progress: ProgressSink?) async throws {
        let reader = client.fileReader(path: path)
        do {
            let totalBytes = try await reader.fileSize
            let fileManager = FileManager.default
            let directoryURL = localURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: localURL.path) {
                try fileManager.removeItem(at: localURL)
            }
            fileManager.createFile(atPath: localURL.path, contents: nil)
            guard let fileHandle = FileHandle(forWritingAtPath: localURL.path) else {
                throw URLError(.cannotWriteToFile)
            }
            defer {
                try? fileHandle.close()
            }

            var offset: UInt64 = 0
            let chunkSize: UInt32 = 1_048_576
            while offset < totalBytes {
                let remaining = min(UInt64(chunkSize), totalBytes - offset)
                let data = try await reader.read(offset: offset, length: UInt32(remaining))
                if data.isEmpty {
                    break
                }
                try fileHandle.write(contentsOf: data)
                offset += UInt64(data.count)
                await progress?(TransferProgress(
                    completedBytes: Int64.clamping(offset),
                    totalBytes: Int64.clamping(totalBytes)
                ))
            }
            await progress?(TransferProgress(
                completedBytes: Int64.clamping(offset),
                totalBytes: Int64.clamping(totalBytes)
            ))
            try await reader.close()
        } catch {
            try? await reader.close()
            throw error
        }
    }
}

private enum SMBPathFormatter {
    static func smbPath(from path: RemotePath) -> String {
        path.displayPath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }
}

private extension SMBRemoteItemKind {
    var remoteEntryKind: RemoteEntryKind {
        switch self {
        case .file:
            return .file
        case .directory:
            return .directory
        }
    }
}

private extension Int64 {
    static func clamping(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}

private enum RedactedValue {
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
