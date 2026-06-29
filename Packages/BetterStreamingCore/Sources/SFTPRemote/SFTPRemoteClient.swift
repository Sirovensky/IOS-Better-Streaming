import BetterStreamingDomain
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
            let listings = try await sftp.listDirectory(atPath: resolvedPath(directory))
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
            throw Self.map(error, path: directory)
        }
    }

    public func stat(_ path: RemotePath) async throws -> RemoteMetadata {
        do {
            let sftp = try await activeSFTPClient()
            let attributes = try await sftp.getAttributes(at: resolvedPath(path))
            let kind = SFTPAttributeMapper.kind(fromPermissions: attributes.permissions)
            return RemoteMetadata(
                path: path,
                kind: kind,
                size: kind == .file ? SFTPAttributeMapper.int64Size(attributes.size) : nil,
                modifiedAt: attributes.accessModificationTime?.modificationTime,
                supportsRangeRead: kind == .file
            )
        } catch {
            throw Self.map(error, path: path)
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

        do {
            let sftp = try await activeSFTPClient()
            return try await sftp.withFile(filePath: resolvedPath(path), flags: .read) { file in
                // A single SSH_FXP_READ may return fewer bytes than requested
                // (servers cap per-read at ~64-256KB), so loop until the whole
                // range is read or EOF — otherwise large ranges stream truncated,
                // corrupt audio. Mirrors download()'s chunked read.
                var data = Data(capacity: Int(length))
                var offset = UInt64(range.lowerBound)
                while data.count < Int(length) {
                    let want = UInt32(min(Int(length) - data.count, 262_144))
                    var buffer = try await file.read(from: offset, length: want)
                    guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
                        break   // EOF: return the partial prefix (HTTP range semantics)
                    }
                    data.append(contentsOf: bytes)
                    offset += UInt64(bytes.count)
                }
                return data
            }
        } catch {
            throw Self.map(error, path: path)
        }
    }

    public func download(_ path: RemotePath, to localURL: URL, progress: ProgressSink?) async throws {
        do {
            let metadata = try await stat(path)
            let totalBytes = metadata.size
            let sftp = try await activeSFTPClient()
            let directory = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let tempURL = directory.appendingPathComponent("\(UUID().uuidString).download")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: tempURL.path) else {
                throw RemoteFileSystemError.invalidResponse
            }

            do {
                let completed = try await sftp.withFile(filePath: resolvedPath(path), flags: .read) { file in
                    var offset: UInt64 = 0
                    var written: Int64 = 0
                    while true {
                        var buffer = try await file.read(from: offset, length: 262_144)
                        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else {
                            return written
                        }
                        try handle.write(contentsOf: Data(bytes))
                        offset += UInt64(bytes.count)
                        written += Int64(bytes.count)
                        await progress?(TransferProgress(completedBytes: written, totalBytes: totalBytes))
                        try Task.checkCancellation()
                    }
                }
                try handle.close()
                if FileManager.default.fileExists(atPath: localURL.path) {
                    try FileManager.default.removeItem(at: localURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: localURL)
                await progress?(TransferProgress(completedBytes: completed, totalBytes: totalBytes ?? completed))
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        } catch {
            throw Self.map(error, path: path)
        }
    }
}

extension SFTPRemoteClient {
    /// Release the SSH session (and with it the SFTP subsystem). Without this,
    /// the protocol's default no-op left the session open on app background /
    /// source removal. Reconnects lazily on the next operation.
    public func disconnect() async {
        if let sshClient { try? await sshClient.close() }
        sshClient = nil
        sftpClient = nil
    }

    private func activeSFTPClient() async throws -> SFTPClient {
        if let sftpClient, sftpClient.isActive {
            return sftpClient
        }
        if let sshClient, !sshClient.isConnected {
            try? await sshClient.close()
            self.sshClient = nil
            self.sftpClient = nil
        }
        let ssh = try await activeSSHClient()
        let sftp = try await ssh.openSFTP()
        self.sftpClient = sftp
        return sftp
    }

    private func activeSSHClient() async throws -> SSHClient {
        if let sshClient, sshClient.isConnected {
            return sshClient
        }
        let username = self.username
        let password = self.password
        let settings = SSHClientSettings(
            host: host,
            port: port == 0 ? 22 : port,
            authenticationMethod: {
                .passwordBased(username: username, password: password)
            },
            // Trust-on-first-use: record the host key on first connect and reject
            // a changed key thereafter, instead of blindly accepting any key
            // (which allowed a man-in-the-middle to capture credentials).
            hostKeyValidator: .custom(TOFUHostKeyValidator(host: host, port: port == 0 ? 22 : port))
        )
        let client = try await SSHClient.connect(to: settings)
        self.sshClient = client
        return client
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
    private let storeURL: URL
    private static let lock = NSLock()

    init(host: String, port: Int) {
        self.endpoint = "\(host):\(port)"
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        self.storeURL = support.appendingPathComponent("ssh_known_hosts.json")
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = hostKey.write(to: &buffer)
        let bytes = buffer.getBytes(at: 0, length: buffer.readableBytes) ?? []
        let fingerprint = Data(bytes).base64EncodedString()

        Self.lock.lock()
        defer { Self.lock.unlock() }
        var known = loadKnownHosts()
        if let existing = known[endpoint] {
            if existing == fingerprint {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SFTPHostKeyError.changed(endpoint))
            }
        } else {
            known[endpoint] = fingerprint   // trust on first use
            saveKnownHosts(known)
            validationCompletePromise.succeed(())
        }
    }

    private func loadKnownHosts() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private func saveKnownHosts(_ dict: [String: String]) {
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}

enum SFTPHostKeyError: LocalizedError {
    case changed(String)

    var errorDescription: String? {
        switch self {
        case .changed(let endpoint):
            return "The SSH host key for \(endpoint) has changed. This may indicate a man-in-the-middle attack, or the server was reinstalled. The saved key must be cleared to reconnect."
        }
    }
}
