import EvensongDomain
@preconcurrency import Citadel
import Foundation
import NIO
@preconcurrency import NIOSSH
import RemoteFileSystem

public actor SFTPRemoteClient: RemoteFileSystemClient {
    public nonisolated let capabilities = RemoteCapabilities(
        supportsByteRangeRead: true,
        supportsServerSideSearch: false,
        supportsStableFileID: false,
        supportsDirectoryModifiedTime: true,
        supportsBackgroundURLSession: false
    )

    private let host: String
    private let port: Int
    private let basePath: String
    private let username: String
    private let password: String
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?
    private var connectTask: Task<SSHClient, Error>?
    private var sftpOpenTask: Task<SFTPClient, Error>?

    /// Open read handles pooled by resolved path. Re-opening (OPEN + CLOSE) on
    /// every 512 KB streaming chunk added two serialized round-trips per chunk;
    /// reusing one handle collapses that to just the READs. Small LRU cap; entries
    /// dropped on error and flushed on reconnect / disconnect. Mirrors SMB's pool.
    private var openFiles: [String: SFTPFile] = [:]
    private var openFileOrder: [String] = []
    /// Memoised in-flight opens so two concurrent first-reads of the same path
    /// don't both OPEN and orphan the loser's handle.
    private var openFileTasks: [String: Task<SFTPFile, Error>] = [:]
    private static let maxOpenFiles = 4

    /// A single ranged read is split into up to this many concurrent chunk reads
    /// of this size, stitched back in order. Citadel multiplexes requests on the
    /// SSH channel, so overlapping READs pipeline instead of serializing — a large
    /// range no longer waits on one 256 KB round-trip at a time.
    private static let readChunkSize = 262_144
    private static let readConcurrency = 4

    /// Wall-clock ceiling for a single list / stat / chunk read. Citadel honours
    /// no cancellation on a wedged receive; on a trip we drop the SSH client so the
    /// next op reconnects lazily. Generous so a slow-but-alive link isn't cut.
    private static let opTimeoutNanos: UInt64 = 30_000_000_000   // 30s

    public init(
        host: String,
        port: Int = 22,
        basePath: String = "",
        username: String,
        password: String
    ) {
        self.host = host
        self.port = port
        self.basePath = basePath
        self.username = username
        self.password = password
    }

    public func list(_ directory: RemotePath) async throws -> [RemoteEntry] {
        do {
            let sftp = try await activeSFTPClient()
            let path = resolvedPath(directory)
            let listings = try await RemoteTimeout.run(Self.opTimeoutNanos) {
                try await sftp.listDirectory(atPath: path)
            }
            return listings
                .flatMap(\.components)
                .compactMap { component -> RemoteEntry? in
                    let name = component.filename.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, name != ".", name != ".." else { return nil }
                    let kind = SFTPAttributeMapper.kind(fromPermissions: component.attributes.permissions)
                    return RemoteEntry(
                        name: name,
                        path: directory.appending(name),
                        kind: kind,
                        size: kind == .file ? SFTPAttributeMapper.int64Size(component.attributes.size) : nil,
                        modifiedAt: component.attributes.accessModificationTime?.modificationTime
                    )
                }
                .sortedDeterministically()
        } catch {
            throw await mapAndMaybeTeardown(error, path: directory)
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteMetadata {
        do {
            let sftp = try await activeSFTPClient()
            let resolved = resolvedPath(path)
            let attributes = try await RemoteTimeout.run(Self.opTimeoutNanos) {
                try await sftp.getAttributes(at: resolved)
            }
            let kind = SFTPAttributeMapper.kind(fromPermissions: attributes.permissions)
            return RemoteMetadata(
                path: path,
                kind: kind,
                size: kind == .file ? SFTPAttributeMapper.int64Size(attributes.size) : nil,
                modifiedAt: attributes.accessModificationTime?.modificationTime,
                supportsRangeRead: kind == .file
            )
        } catch {
            throw await mapAndMaybeTeardown(error, path: path)
        }
    }

    public func read(_ path: RemotePath, range: Range<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound else {
            throw RemoteFileSystemError.unsupportedRange
        }
        let length = range.upperBound - range.lowerBound
        guard length > 0 else { return Data() }
        guard length <= Int64(UInt32.max) else {
            throw RemoteFileSystemError.unsupportedRange
        }

        let resolved = resolvedPath(path)
        do {
            return try await readRange(resolved: resolved, start: UInt64(range.lowerBound), length: Int(length))
        } catch {
            throw await mapAndMaybeTeardown(error, path: path)
        }
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink?) async throws {
        do {
            let metadata = try await stat(path)
            let totalBytes = metadata.size
            let resolved = resolvedPath(path)
            let directory = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let tempURL = directory.appendingPathComponent("\(UUID().uuidString).download")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: tempURL.path) else {
                throw RemoteFileSystemError.invalidResponse
            }

            do {
                let file = try await pooledFile(for: resolved)
                var offset: UInt64 = 0
                var written: Int64 = 0
                // Read a 1 MB window per iteration (4×256 KB issued concurrently),
                // write it, then advance — streams to disk without buffering the
                // whole file, while still pipelining the reads.
                let windowSize = Self.readChunkSize * Self.readConcurrency
                while true {
                    let data = try await concurrentRead(file: file, start: offset, length: windowSize)
                    if data.isEmpty { break }
                    try handle.write(contentsOf: data)
                    offset += UInt64(data.count)
                    written += Int64(data.count)
                    await progress?(TransferProgress(completedBytes: written, totalBytes: totalBytes))
                    try Task.checkCancellation()
                    if data.count < windowSize { break }   // short window = EOF
                }
                try handle.close()
                // Short-read guard (FTP has the same): a server that returns an
                // early empty read looks like EOF and would move a truncated file
                // into place as if complete. Reject it.
                if let totalBytes, totalBytes > 0, written < totalBytes {
                    throw RemoteFileSystemError.serverDisconnected
                }
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.removeItem(at: localURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: localURL)
                await progress?(TransferProgress(completedBytes: written, totalBytes: totalBytes ?? written))
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: tempURL)
                await dropFile(resolved)   // a failed chunk may have left a stale handle pooled
                throw error
            }
        } catch {
            throw await mapAndMaybeTeardown(error, path: path)
        }
    }
}

extension SFTPRemoteClient {
    /// Release the SSH session (and with it the SFTP subsystem). Without this,
    /// the protocol's default no-op left the session open on app background /
    /// source removal. Reconnects lazily on the next operation.
    public func disconnect() async {
        connectTask?.cancel()
        connectTask = nil
        sftpOpenTask?.cancel()
        sftpOpenTask = nil
        // Closing the SSH client drops the channel, which frees every pooled file
        // handle server-side — so just clear the pool without per-handle CLOSEs.
        flushFilePool()
        if let sshClient { try? await sshClient.close() }
        sshClient = nil
        sftpClient = nil
    }

    /// Map a thrown error and, when it's a wall-clock timeout (a wedged receive),
    /// tear the SSH client down so the next op reconnects on a fresh session.
    private func mapAndMaybeTeardown(_ error: Error, path: RemotePath) async -> Error {
        let mapped = Self.map(error, path: path)
        if let rfs = mapped as? RemoteFileSystemError, rfs == .timeout {
            await disconnect()
        }
        return mapped
    }

    /// Read `[start, start+length)` as up to `readConcurrency` overlapping chunk
    /// reads on the pooled handle, retrying once on a fresh handle if the pooled
    /// one turns out stale (idle-closed / reconnected). A timeout is NOT retried —
    /// the caller tears the connection down for that.
    private func readRange(resolved: String, start: UInt64, length: Int) async throws -> Data {
        do {
            let file = try await pooledFile(for: resolved)
            return try await concurrentRead(file: file, start: start, length: length)
        } catch let error as RemoteFileSystemError where error == .timeout {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await dropFile(resolved)
            let file = try await pooledFile(for: resolved)
            return try await concurrentRead(file: file, start: start, length: length)
        }
    }

    private func concurrentRead(file: SFTPFile, start: UInt64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let chunkSize = Self.readChunkSize
        let chunkCount = (length + chunkSize - 1) / chunkSize
        var chunks = [Data?](repeating: nil, count: chunkCount)
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            let maxInFlight = min(Self.readConcurrency, chunkCount)
            func schedule(_ index: Int) {
                let chunkStart = start + UInt64(index * chunkSize)
                let chunkLen = min(chunkSize, length - index * chunkSize)
                group.addTask {
                    let data = try await RemoteTimeout.run(Self.opTimeoutNanos) {
                        try await Self.readFully(file: file, start: chunkStart, length: chunkLen)
                    }
                    return (index, data)
                }
            }
            while next < maxInFlight { schedule(next); next += 1 }
            while let (index, data) = try await group.next() {
                chunks[index] = data
                if next < chunkCount { schedule(next); next += 1 }
            }
        }
        // Stitch in order, stopping at the first short/empty chunk (EOF) — anything
        // past it is beyond the file, so the returned prefix is the valid range.
        var result = Data(capacity: length)
        for index in 0..<chunkCount {
            guard let chunk = chunks[index], !chunk.isEmpty else { break }
            result.append(chunk)
            if chunk.count < min(chunkSize, length - index * chunkSize) { break }
        }
        return result
    }

    /// Fully read one chunk's sub-range, looping over the per-read cap the server
    /// enforces (~64-256 KB) until the chunk is filled or EOF.
    private static func readFully(file: SFTPFile, start: UInt64, length: Int) async throws -> Data {
        var data = Data(capacity: length)
        var offset = start
        while data.count < length {
            let want = UInt32(min(length - data.count, Int(UInt32.max)))
            var buffer = try await file.read(from: offset, length: want)
            guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
                break   // EOF
            }
            data.append(contentsOf: bytes)
            offset += UInt64(bytes.count)
        }
        return data
    }

    /// Return the pooled read handle for `resolved`, opening (and pooling) one on
    /// first use. The in-flight open is memoised so concurrent first-reads share it.
    private func pooledFile(for resolved: String) async throws -> SFTPFile {
        if let existing = openFiles[resolved], existing.isActive {
            touchFile(resolved)
            return existing
        }
        if let task = openFileTasks[resolved] {
            if let file = try? await task.value, file.isActive { return file }
        }
        let sftp = try await activeSFTPClient()
        let task = Task<SFTPFile, Error> {
            try await sftp.openFile(filePath: resolved, flags: .read)
        }
        openFileTasks[resolved] = task
        do {
            let file = try await task.value
            guard openFileTasks[resolved] == task else {
                // disconnect()/dropFile raced us — don't resurrect into a torn pool.
                try? await file.close()
                throw RemoteFileSystemError.serverDisconnected
            }
            openFileTasks[resolved] = nil
            store(file, for: resolved)
            return file
        } catch {
            if openFileTasks[resolved] == task { openFileTasks[resolved] = nil }
            throw error
        }
    }

    private func store(_ file: SFTPFile, for resolved: String) {
        openFiles[resolved] = file
        touchFile(resolved)
        while openFileOrder.count > Self.maxOpenFiles {
            let victim = openFileOrder.removeFirst()
            if victim == resolved { openFileOrder.append(resolved); continue }
            if let evicted = openFiles.removeValue(forKey: victim) {
                Task { try? await evicted.close() }   // best-effort, off the hot path
            }
        }
    }

    private func touchFile(_ resolved: String) {
        if let idx = openFileOrder.firstIndex(of: resolved) { openFileOrder.remove(at: idx) }
        openFileOrder.append(resolved)
    }

    /// Drop (and close) the pooled handle for `resolved` so the next read re-opens.
    private func dropFile(_ resolved: String) async {
        openFileTasks[resolved]?.cancel()
        openFileTasks[resolved] = nil
        if let idx = openFileOrder.firstIndex(of: resolved) { openFileOrder.remove(at: idx) }
        if let file = openFiles.removeValue(forKey: resolved) {
            try? await file.close()
        }
    }

    /// Drop all pooled handles WITHOUT per-handle CLOSEs (used when the channel is
    /// already gone / being torn down, where a CLOSE would just fail).
    private func flushFilePool() {
        for task in openFileTasks.values { task.cancel() }
        openFileTasks.removeAll()
        openFiles.removeAll()
        openFileOrder.removeAll()
    }

    private func activeSFTPClient() async throws -> SFTPClient {
        if let sftpClient, sftpClient.isActive {
            return sftpClient
        }
        if let sshClient, !sshClient.isConnected {
            try? await sshClient.close()
            self.sshClient = nil
            self.sftpClient = nil
            flushFilePool()   // pooled handles belonged to the dead channel
        }
        // Memoised like the SSH connect below: two concurrent first ops would
        // otherwise both open an SFTP channel and orphan the loser's.
        if let sftpOpenTask {
            if let sftp = try? await sftpOpenTask.value, sftp.isActive {
                return sftp
            }
        }
        let ssh = try await activeSSHClient()
        let task = Task<SFTPClient, Error> {
            try await ssh.openSFTP()
        }
        sftpOpenTask = task
        do {
            let sftp = try await task.value
            if sftpOpenTask == task {
                sftpClient = sftp
                sftpOpenTask = nil
            } else {
                // disconnect() raced us — don't resurrect a torn-down channel.
                try? await sftp.close()
            }
            return sftp
        } catch {
            if sftpOpenTask == task { sftpOpenTask = nil }
            throw error
        }
    }

    private func activeSSHClient() async throws -> SSHClient {
        if let sshClient, sshClient.isConnected {
            return sshClient
        }
        // Memoise the in-flight connect so concurrent operations (actor reentrancy
        // across the connect await) share ONE SSH session. Without this, both
        // callers saw nil, both connected, and the loser's session leaked open.
        if let connectTask {
            if let client = try? await connectTask.value, client.isConnected {
                return client
            }
        }

        let username = self.username
        let password = self.password
        let resolvedPort = port == 0 ? 22 : port
        let settings = SSHClientSettings(
            host: host,
            port: resolvedPort,
            authenticationMethod: {
                .passwordBased(username: username, password: password)
            },
            // Trust-on-first-use: record the host key on first connect and reject
            // a changed key thereafter, instead of blindly accepting any key
            // (which allowed a man-in-the-middle to capture credentials).
            hostKeyValidator: .custom(TOFUHostKeyValidator(host: host, port: resolvedPort))
        )
        let task = Task<SSHClient, Error> {
            try await SSHClient.connect(to: settings)
        }
        connectTask = task
        do {
            let client = try await task.value
            if connectTask == task {
                sshClient = client
                connectTask = nil
            } else {
                // disconnect() ran while we were connecting and Citadel ignored
                // the cancellation — close the orphan instead of resurrecting it.
                try? await client.close()
                throw RemoteFileSystemError.serverDisconnected
            }
            return client
        } catch {
            if connectTask == task { connectTask = nil }   // clear so the next op retries
            throw error
        }
    }

    private func resolvedPath(_ path: RemotePath) -> String {
        let base = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let child = path.displayPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if base.isEmpty && child.isEmpty { return "." }
        if base.isEmpty { return "/" + child }
        if child.isEmpty { return "/" + base }
        return "/" + base + "/" + child
    }

    static func map(_ error: Error, path: RemotePath) -> Error {
        if let error = error as? RemoteFileSystemError { return error }
        if error is CancellationError { return RemoteFileSystemError.cancelled }
        let text = String(describing: error).lowercased()
        if text.contains("authentication") || text.contains("password") || text.contains("permission denied") {
            return RemoteFileSystemError.authenticationExpired
        }
        if text.contains("not found") || text.contains("no such file") || text.contains("does not exist") {
            return RemoteFileSystemError.notFound(path)
        }
        if text.contains("eof") || text.contains("closed") || text.contains("disconnected") {
            return RemoteFileSystemError.serverDisconnected
        }
        return RemoteFileSystemError.invalidResponse
    }
}

enum SFTPAttributeMapper {
    static func kind(fromPermissions permissions: UInt32?) -> RemoteEntryKind {
        guard let permissions else { return .file }
        switch permissions & 0o170000 {
        case 0o040000:
            return .directory
        case 0o100000:
            return .file
        case 0o120000:
            return .symbolicLink
        default:
            return .unknown
        }
    }

    static func int64Size(_ size: UInt64?) -> Int64? {
        guard let size, size <= UInt64(Int64.max) else { return nil }
        return Int64(size)
    }
}

/// Trust-on-first-use SSH host-key validator. Records each endpoint's host key
/// the first time it connects, then rejects any later connection whose key has
/// changed (a sign of a man-in-the-middle or a reprovisioned server). Replaces
/// the previous accept-anything behaviour that exposed SFTP credentials to MITM.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let endpoint: String
    private let storeURL: URL?
    private static let lock = NSLock()
    // Serialise (and get OFF the NIO event loop) the known-hosts file IO. Doing
    // synchronous disk IO under a lock directly on the event loop stalled the
    // whole SSH channel.
    private static let ioQueue = DispatchQueue(label: "Evensong.SFTP.knownHosts")

    init(host: String, port: Int) {
        self.endpoint = "\(host):\(port)"
        self.storeURL = Self.defaultStoreURL()
    }

    /// Test seam. Pass a scratch store path, or `nil` to simulate Application
    /// Support being unavailable.
    init(endpoint: String, storeURL: URL?) {
        self.endpoint = endpoint
        self.storeURL = storeURL
    }

    static func defaultStoreURL() -> URL? {
        // Fail closed: no temporary-directory fallback. The OS purges tmp, which
        // would make every reconnect a "first use" and silently reopen the MITM
        // window the TOFU check exists to close.
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else {
            return nil
        }
        return support.appendingPathComponent("ssh_known_hosts.json")
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = Self.fingerprint(of: hostKey)
        let endpoint = self.endpoint
        let storeURL = self.storeURL
        Self.ioQueue.async {
            switch Self.decide(endpoint: endpoint, fingerprint: fingerprint, storeURL: storeURL) {
            case .success:
                validationCompletePromise.succeed(())
            case .failure(let error):
                validationCompletePromise.fail(error)
            }
        }
    }

    static func fingerprint(of hostKey: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = hostKey.write(to: &buffer)
        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) ?? []
        return Data(bytes).base64EncodedString()
    }

    /// Pure TOFU decision — first-use records the key and accepts; a changed key
    /// is rejected; a missing/unwritable store fails closed. Unit-testable with a
    /// scratch known-hosts path.
    static func decide(endpoint: String, fingerprint: String, storeURL: URL?) -> Result<Void, Error> {
        guard let storeURL else {
            return .failure(SFTPHostKeyError.storeUnavailable)
        }
        lock.lock()
        defer { lock.unlock() }
        var known = loadKnownHosts(storeURL)
        if let existing = known[endpoint] {
            return existing == fingerprint ? .success(()) : .failure(SFTPHostKeyError.changed(endpoint))
        }
        known[endpoint] = fingerprint   // trust on first use
        guard saveKnownHosts(known, to: storeURL) else {
            // Can't persist the trusted key → can't enforce TOFU next time, so
            // fail closed rather than trust a key we won't remember.
            return .failure(SFTPHostKeyError.storeUnavailable)
        }
        return .success(())
    }

    static func loadKnownHosts(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    @discardableResult
    static func saveKnownHosts(_ dict: [String: String], to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

enum SFTPHostKeyError: LocalizedError {
    case changed(String)
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .changed(let endpoint):
            return "The SSH host key for \(endpoint) has changed. This may indicate a man-in-the-middle attack, or the server was reinstalled. The saved key must be cleared to reconnect."
        case .storeUnavailable:
            return "The known-hosts store is unavailable, so the SSH host key can't be verified. The connection was refused to avoid a man-in-the-middle risk."
        }
    }
}
