import Foundation
import EvensongDomain
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

public protocol SMBRemoteTransport: AnyObject, Sendable {
    func listDirectory(path: String) async throws -> [SMBRemoteItem]
    func metadata(path: String) async throws -> SMBRemoteMetadata
    func read(path: String, offset: Int64, length: Int64) async throws -> Data
    func download(path: String, to localURL: URL, progress: ProgressSink?) async throws
    /// Tear down the underlying connection WITHOUT issuing any graceful SMB
    /// close/logoff (those would block on a wedged connection). Must be
    /// non-blocking: it only cancels the transport's socket so any in-flight or
    /// queued operation on it unwinds with an error. Idempotent.
    func disconnect()
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

    /// Wall-clock ceiling for a single ranged read. The underlying SMBClient has
    /// NO receive timeout: a stalled receive (dropped packet, Wi-Fi power-save,
    /// NAS hiccup) never returns and never throws, and — because every op
    /// serializes behind one connection semaphore that is only released after the
    /// receive completes — it wedges the whole connection forever. We bound the
    /// read, orphan the wedged connection, and reconnect on a fresh one.
    /// Instance-level (not static) so tests can inject a short value.
    private let readTimeoutNanos: UInt64
    /// Ceiling for establishing a connection (TCP + negotiate + auth + tree
    /// connect). Same hang risk as reads on a half-open connection.
    private let connectTimeoutNanos: UInt64

    /// Serializes every operation on this client so only ONE is in flight at a
    /// time. The underlying SMBClient already serializes the wire behind a single
    /// connection semaphore — BUT it allocates each SMB2 message-id OUTSIDE that
    /// semaphore (`Session.messageId`, a plain class), so two concurrent reads
    /// (AVPlayer's all-to-end fill loop + a scrub's bounded read) race the id and
    /// desync the protocol → a silent hang or garbage/silent audio (the "scrub →
    /// plays but no sound" bug). Serializing here is effectively free (the wire
    /// was already serial) and also removes the concurrent shared-`FileReader`
    /// hazards. FIFO, so a queued scrub read is never starved by a tight fill loop.
    private var opLocked = false
    private var opWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        configuration: SMBConnectionConfiguration,
        authentication: SMBAuthentication? = nil,
        transportFactory: SMBRemoteTransportFactory? = nil
    ) {
        self.init(
            configuration: configuration,
            authentication: authentication,
            transportFactory: transportFactory,
            readTimeoutNanos: 10_000_000_000,      // 10s
            connectTimeoutNanos: 12_000_000_000    // 12s
        )
    }

    /// Designated init exposing the timeouts for tests (`@testable`).
    init(
        configuration: SMBConnectionConfiguration,
        authentication: SMBAuthentication?,
        transportFactory: SMBRemoteTransportFactory?,
        readTimeoutNanos: UInt64,
        connectTimeoutNanos: UInt64
    ) {
        self.configuration = configuration
        self.authentication = authentication ?? SMBAuthentication(
            username: configuration.username,
            domain: configuration.domain
        )
        self.transportFactory = transportFactory ?? LiveSMBRemoteTransport.make
        self.readTimeoutNanos = readTimeoutNanos
        self.connectTimeoutNanos = connectTimeoutNanos
    }

    public func list(_ directory: RemotePath) async throws -> [RemoteEntry] {
        await acquireOpLock()
        defer { releaseOpLock() }
        var used: (any SMBRemoteTransport)?
        do {
            let transport = try await activeTransport()
            used = transport
            let smbPath = SMBPathFormatter.smbPath(from: directory)
            return try await Self.withTimeout(readTimeoutNanos) {
                try await transport.listDirectory(path: smbPath)
            }
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
            try handleFailure(error, path: directory, transport: used)
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteMetadata {
        await acquireOpLock()
        defer { releaseOpLock() }
        var used: (any SMBRemoteTransport)?
        do {
            let transport = try await activeTransport()
            used = transport
            let smbPath = SMBPathFormatter.smbPath(from: path)
            let metadata = try await Self.withTimeout(readTimeoutNanos) {
                try await transport.metadata(path: smbPath)
            }
            return RemoteMetadata(
                path: path,
                kind: metadata.kind.remoteEntryKind,
                size: metadata.kind == .file ? metadata.size : nil,
                modifiedAt: metadata.modifiedAt,
                fileID: metadata.fileID
            )
        } catch {
            try handleFailure(error, path: path, transport: used)
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
        let smbPath = SMBPathFormatter.smbPath(from: path)
        await acquireOpLock()
        defer { releaseOpLock() }
        var used: (any SMBRemoteTransport)?
        do {
            let transport = try await activeTransport()
            used = transport
            return try await Self.withTimeout(readTimeoutNanos) {
                try await transport.read(path: smbPath, offset: range.lowerBound, length: length)
            }
        } catch {
            try handleFailure(error, path: path, transport: used)
        }
    }

    /// Map a thrown SMB error and, when it indicates the connection itself died
    /// (or wedged — see `.timeout` from `withTimeout`), drop AND tear down the
    /// cached transport so the NEXT operation reconnects on a fresh one.
    ///
    /// Tearing down (vs. the old "just drop the reference") matters for the
    /// timeout case: the orphaned read is still suspended inside the wedged
    /// connection's `receive`, holding its one-permit semaphore. Cancelling that
    /// connection's socket (`disconnect()` → `NWConnection.cancel()`, which is
    /// non-blocking and issues NO further SMB traffic) makes the pending receive
    /// fail, which resumes the orphaned read with an error so it unwinds and
    /// releases the semaphore. We never reuse that connection, so there is no
    /// receive-buffer desync (the old `EXC_BREAKPOINT in ByteReader` came from
    /// REUSING a connection whose read had been abandoned — we don't).
    ///
    /// Only reset when the failed transport is STILL the current one: a stale
    /// failure from a slow concurrent op must not tear down a healthy transport
    /// that a sibling op already reconnected.
    private func handleFailure(
        _ error: Error,
        path: RemotePath,
        transport failed: (any SMBRemoteTransport)?
    ) throws -> Never {
        let mapped = Self.remoteFileSystemError(from: error, path: path)
        if let rfs = mapped as? RemoteFileSystemError {
            switch rfs {
            case .serverDisconnected, .timeout, .invalidResponse:
                resetTransport(ifCurrent: failed)
            default:
                break
            }
        }
        throw mapped
    }

    /// Drop and tear down `transport` iff it is still the one that failed
    /// (`SMBRemoteTransport` is `AnyObject`, so this identity check is sound).
    private func resetTransport(ifCurrent failed: (any SMBRemoteTransport)?) {
        guard let failed, let current = transport, current === failed else { return }
        transport = nil
        failed.disconnect()
    }

    /// Acquire the per-client operation lock (FIFO). Held across one transport op.
    private func acquireOpLock() async {
        if !opLocked {
            opLocked = true
            return
        }
        await withCheckedContinuation { opWaiters.append($0) }
    }

    private func releaseOpLock() {
        if opWaiters.isEmpty {
            opLocked = false
        } else {
            opWaiters.removeFirst().resume()
        }
    }

    /// Race `op` against a wall-clock timeout WITHOUT relying on cancellation of
    /// the underlying work (the SMBClient honours no cancellation). The op runs
    /// in an UNSTRUCTURED task so that, on timeout, this function returns while
    /// the op is left to unwind on its own once its transport is torn down — a
    /// structured `TaskGroup` would instead block here awaiting the hung child.
    fileprivate static func withTimeout<T: Sendable>(
        _ nanoseconds: UInt64,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let sleeper = Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                if gate.tryResume() { continuation.resume(throwing: RemoteFileSystemError.timeout) }
            }
            Task {
                do {
                    let value = try await op()
                    // Cancel the sleeper the instant we win the gate so it doesn't
                    // linger (and hold its continuation capture) for the full
                    // timeout after the op already returned.
                    if gate.tryResume() { sleeper.cancel(); continuation.resume(returning: value) }
                } catch {
                    if gate.tryResume() { sleeper.cancel(); continuation.resume(throwing: error) }
                }
            }
        }
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink?) async throws {
        await acquireOpLock()
        defer { releaseOpLock() }
        var used: (any SMBRemoteTransport)?
        do {
            let transport = try await activeTransport()
            used = transport
            try await transport.download(
                path: SMBPathFormatter.smbPath(from: path),
                to: localURL,
                progress: progress
            )
        } catch {
            // Same orphan-and-reconnect as reads: a wedged chunk (the transport
            // bounds each chunk read with `withTimeout`) surfaces as `.timeout`,
            // which tears down this connection so the next op reconnects — and so
            // a hung download can't hold the op-lock (and the whole background
            // connection) forever.
            try handleFailure(error, path: path, transport: used)
        }
    }

    /// Tear down the cached connection without blocking (no graceful SMB
    /// logoff/close — those would hang on a wedged connection). Idempotent; the
    /// next operation reconnects on a fresh transport. Frees the server-side
    /// session, which is what stops a long-lived app from exhausting the NAS
    /// session table.
    public func disconnect() async {
        guard let current = transport else { return }
        transport = nil
        current.disconnect()
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
        let factory = transportFactory
        let config = configuration
        let auth = authentication
        // Connect-specific timeout: if the connect overruns the deadline but then
        // SUCCEEDS, the late transport owns a live NWConnection — disconnect it so
        // it doesn't leak a server session (the generic withTimeout would just
        // drop the value). Idempotent disconnect is non-blocking.
        let newTransport = try await Self.connectWithTimeout(connectTimeoutNanos, factory: factory, config: config, auth: auth)
        transport = newTransport
        return newTransport
    }

    private static func connectWithTimeout(
        _ nanoseconds: UInt64,
        factory: @escaping SMBRemoteTransportFactory,
        config: SMBConnectionConfiguration,
        auth: SMBAuthentication
    ) async throws -> any SMBRemoteTransport {
        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<any SMBRemoteTransport, Error>) in
            let sleeper = Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                if gate.tryResume() { continuation.resume(throwing: RemoteFileSystemError.timeout) }
            }
            Task {
                do {
                    let transport = try await factory(config, auth)
                    if gate.tryResume() {
                        sleeper.cancel()
                        continuation.resume(returning: transport)
                    } else {
                        transport.disconnect()   // timed out already — don't leak the late connection
                    }
                } catch {
                    if gate.tryResume() { sleeper.cancel(); continuation.resume(throwing: error) }
                }
            }
        }
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
    /// Active read count per path. A reader is never evicted/closed while a read
    /// is in flight on it (would be a use-after-close → connection-buffer desync).
    private var inUse: [String: Int] = [:]
    private static let maxPooledReaders = 4
    /// Wall-clock ceiling for a single download chunk read. A whole-file download
    /// can't reuse the per-op read timeout (it's one op holding the lock for the
    /// entire transfer), so each 1 MB chunk is bounded here. Generous so a slow-
    /// but-alive link isn't cut off; a genuinely wedged receive trips it and the
    /// client tears the connection down. 30s ≫ the time a 1 MB chunk needs.
    private static let downloadChunkTimeoutNanos: UInt64 = 30_000_000_000

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
        // `reader(for:)` hands back a reader already marked in-use (so a
        // concurrent open of another path can't evict+close it mid-read).
        let reader = try await reader(for: path)
        defer { endUse(path) }
        do {
            return try await reader.read(offset: UInt64(offset), length: UInt32(length))
        } catch {
            if let dropped = dropReader(path: path, ifSameAs: reader) {
                try? await dropped.close()
            }
            throw error
        }
    }

    /// Return the pooled reader for `path`, opening (and pooling) one if needed,
    /// and mark it in-use (caller must `endUse`). Opening forces the lazy SMB
    /// CREATE so open errors surface here, not later.
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
        inUse[path, default: 0] += 1
        return reader
    }

    private func endUse(_ path: String) {
        poolLock.lock(); defer { poolLock.unlock() }
        if let count = inUse[path] {
            if count <= 1 { inUse[path] = nil } else { inUse[path] = count - 1 }
        }
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
            inUse[path, default: 0] += 1
            return (existing, reader, [])
        }
        readers[path] = reader
        touchLocked(path)
        inUse[path, default: 0] += 1
        var evicted: [FileReader] = []
        // Evict the oldest IDLE reader (never one with an in-flight read).
        while readerOrder.count > Self.maxPooledReaders {
            guard let idx = readerOrder.firstIndex(where: { (inUse[$0] ?? 0) == 0 }) else { break }
            let stale = readerOrder.remove(at: idx)
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
        // Stream chunks through the pooled `read(path:offset:length:)`. Each chunk
        // (and the size probe) is bounded by `withTimeout`: a whole-file download
        // is one op holding the lock for the entire transfer, so it can't reuse
        // the per-op read timeout. Reads go through `self` (`@unchecked Sendable`)
        // with value-type args so nothing non-`Sendable` (the `FileReader`)
        // crosses the timeout's task.
        let total = try await SMBRemoteClient.withTimeout(Self.downloadChunkTimeoutNanos) { [self] in
            try await self.metadata(path: path).size ?? 0
        }
        // A nil/zero size would otherwise write an empty file and report success,
        // which `playableURL` then caches as a "complete" download → unplayable.
        guard total > 0 else { throw RemoteFileSystemError.invalidResponse }

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
        defer { try? fileHandle.close() }

        var offset: Int64 = 0
        let chunkSize: Int64 = 1_048_576
        while offset < total {
            let remaining = min(chunkSize, total - offset)
            let readOffset = offset
            let data = try await SMBRemoteClient.withTimeout(Self.downloadChunkTimeoutNanos) { [self] in
                try await self.read(path: path, offset: readOffset, length: remaining)
            }
            if data.isEmpty { break }
            try fileHandle.write(contentsOf: data)
            offset += Int64(data.count)
            await progress?(TransferProgress(completedBytes: offset, totalBytes: total))
        }
        // A short/empty read before EOF (e.g. a zero-filled bad frame from the
        // bounds-checked ByteReader) would otherwise truncate the file and report
        // success → a corrupt track cached as "complete" and never re-fetched.
        // Treat it as a connection failure so the caller discards the partial.
        guard offset >= total else { throw RemoteFileSystemError.serverDisconnected }
        await progress?(TransferProgress(completedBytes: offset, totalBytes: total))
    }

    func disconnect() {
        // Drop pooled readers WITHOUT a graceful SMB CLOSE: a CLOSE would be sent
        // over a possibly-wedged connection and block. Cancelling the socket below
        // makes any in-flight read/close on those readers fail and unwind.
        poolLock.lock()
        readers.removeAll()
        readerOrder.removeAll()
        inUse.removeAll()
        poolLock.unlock()
        // Non-blocking: cancels the NWConnection. Pending receive(s) complete with
        // an error, which resumes the connection's send-continuation and releases
        // its one-permit semaphore, so every queued op on this connection unwinds.
        client.session.disconnect()
    }
}

/// One-shot gate: when a continuation is raced between two tasks (the real op
/// and a timeout), this ensures it is resumed exactly once.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
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
