import Darwin
import Foundation
import EvensongDomain
import LibraryIndexer
import RemoteFileSystem
import SMBRemote

@main
struct LiveSMBProbe {
    static func main() async {
        do {
            let configuration = try ProbeConfiguration.environment()
            try await run(configuration)
        } catch {
            writeError("Live SMB probe failed: \(redacted(error))")
            exit(EXIT_FAILURE)
        }
    }

    private static func run(_ probe: ProbeConfiguration) async throws {
        let client = SMBRemoteClient(
            configuration: SMBConnectionConfiguration(
                host: probe.host,
                port: probe.port,
                share: probe.share,
                username: probe.username
            ),
            authentication: .password(username: probe.username, password: probe.password)
        )
        let filter = LibraryScanFilter()
        let classifier = MediaFileClassifier()

        let connection = await client.testConnection()
        print("connection: \(connection.state.rawValue)")
        guard connection.state == .online else {
            throw connection.failure ?? SourceError.hostUnreachable
        }

        let rootPath = RemotePath(displayPath: probe.rootPath)
        let rawRootEntries = try await client.list(rootPath).sortedDeterministically()
        let visibleRootEntries = rawRootEntries.filter { filter.shouldIndex($0) }
        let rootDirectories = visibleRootEntries.filter { $0.kind == .directory }
        let rootFiles = visibleRootEntries.filter { $0.kind == .file }
        let rootMediaFiles = rootFiles.filter { classifier.classify($0) != nil }

        print("rootPath: \(probe.rootPath)")
        print("rootEntries: visible=\(visibleRootEntries.count) ignored=\(rawRootEntries.count - visibleRootEntries.count) directories=\(rootDirectories.count) files=\(rootFiles.count) directMedia=\(rootMediaFiles.count)")
        print("rootSample:")
        for entry in visibleRootEntries.prefix(12) {
            print("  \(entry.kind == .directory ? "dir " : "file") \(entry.name)")
        }

        let sampleFile = try await findSampleMediaFile(
            client: client,
            candidateDirectories: rootDirectories,
            directMediaFiles: rootMediaFiles,
            filter: filter,
            classifier: classifier
        )
        let metadata = try await client.stat(sampleFile.path)
        let readLength = min(max(metadata.size ?? 4096, 1), 4096)
        let data = try await client.read(sampleFile.path, range: 0..<readLength)

        print("sampleMedia: \(sampleFile.path.displayPath)")
        print("sampleSize: \(metadata.size ?? Int64(data.count))")
        print("sampleReadBytes: \(data.count)")
        print("sampleHeaderHex: \(data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))")
    }

    private static func findSampleMediaFile(
        client: SMBRemoteClient,
        candidateDirectories: [RemoteEntry],
        directMediaFiles: [RemoteEntry],
        filter: LibraryScanFilter,
        classifier: MediaFileClassifier
    ) async throws -> RemoteEntry {
        if let direct = directMediaFiles.first {
            return direct
        }

        for directory in candidateDirectories.prefix(24) {
            let entries = try await client.list(directory.path)
                .filter { filter.shouldIndex($0) }
                .sortedDeterministically()
            if let media = entries.first(where: { classifier.classify($0) != nil }) {
                print("sampleDirectory: \(directory.path.displayPath)")
                return media
            }
        }

        throw RemoteFileSystemError.notFound(RemotePath(displayPath: "first media file"))
    }

    private static func redacted(_ error: Error) -> String {
        if let error = error as? RedactableError {
            return "\(error.diagnosticsCode): \(error.redactedDebugDescription)"
        }
        return "unexpected error"
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private struct ProbeConfiguration {
    var host: String
    var port: Int
    var share: String
    var rootPath: String
    var username: String
    var password: String

    static func environment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws -> ProbeConfiguration {
        ProbeConfiguration(
            host: try required("BETTERSTREAMING_SMB_HOST", env),
            port: Int(env["BETTERSTREAMING_SMB_PORT"] ?? "") ?? 445,
            share: try required("BETTERSTREAMING_SMB_SHARE", env),
            rootPath: env["BETTERSTREAMING_SMB_ROOT"] ?? "",
            username: try required("BETTERSTREAMING_SMB_USERNAME", env),
            password: try required("BETTERSTREAMING_SMB_PASSWORD", env)
        )
    }

    private static func required(_ key: String, _ env: [String: String]) throws -> String {
        guard let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ProbeConfigurationError.missing(key)
        }
        return value
    }
}

private enum ProbeConfigurationError: Error {
    case missing(String)
}
