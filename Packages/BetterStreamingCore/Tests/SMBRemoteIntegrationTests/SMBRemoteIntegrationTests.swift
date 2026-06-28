import Foundation
import Testing
import BetterStreamingDomain
import RemoteFileSystem
import SMBRemote

@Test func smbConfigurationDefaultsToPort445() {
    let configuration = SMBConnectionConfiguration(host: "nas.local", share: "Music")
    #expect(configuration.port == 445)
}

@Test func smbConfigurationValidationReportsMissingRequiredFields() {
    let configuration = SMBConnectionConfiguration(host: " ", port: 70_000, share: "Music/Albums")

    #expect(configuration.validationIssues.contains(.missingHost))
    #expect(configuration.validationIssues.contains(.invalidPort))
    #expect(configuration.validationIssues.contains(.shareContainsPathSeparator))
}

@Test func smbSummariesDoNotExposeSensitiveValues() {
    let configuration = SMBConnectionConfiguration(
        host: "fixture-secret-host.invalid",
        share: "PrivateMusic",
        username: "fixture-user",
        domain: "WORKGROUP"
    )
    let authentication = SMBAuthentication.password(
        username: "fixture-user",
        domain: "WORKGROUP",
        password: "fixture-password-value"
    )

    let rendered = "\(configuration) \(authentication)"

    #expect(!rendered.contains("fixture-secret-host.invalid"))
    #expect(!rendered.contains("PrivateMusic"))
    #expect(!rendered.contains("fixture-user"))
    #expect(!rendered.contains("WORKGROUP"))
    #expect(!rendered.contains("fixture-password-value"))
    #expect(rendered.contains("<redacted>"))
}

@Test func smbRemoteClientMapsTransportOperationsToRemoteFileSystem() async throws {
    let transport = MockSMBTransport()
    let client = SMBRemoteClient(
        configuration: SMBConnectionConfiguration(host: "nas.local", share: "Music"),
        transportFactory: { _, _ in transport }
    )

    let directory = RemotePath(displayPath: "Albums")
    let entries = try await client.list(directory)
    #expect(entries.count == 1)
    #expect(entries.first?.name == "Song.mp3")
    #expect(entries.first?.path.displayPath == "Albums/Song.mp3")
    #expect(entries.first?.kind == .file)

    let filePath = RemotePath(displayPath: "Albums/Song.mp3")
    let metadata = try await client.stat(filePath)
    #expect(metadata.kind == .file)
    #expect(metadata.size == 11)

    let data = try await client.read(filePath, range: 0..<5)
    #expect(String(decoding: data, as: UTF8.self) == "hello")

    let progress = ProgressCollector()
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try await client.download(filePath, to: destination) { update in
        await progress.append(update)
    }
    defer {
        try? FileManager.default.removeItem(at: destination)
    }
    #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self) == "hello world")
    #expect(await progress.events == [TransferProgress(completedBytes: 11, totalBytes: 11)])
}

@Test func smbConnectionTestUsesRootListing() async {
    let transport = MockSMBTransport()
    let client = SMBRemoteClient(
        configuration: SMBConnectionConfiguration(host: "nas.local", share: "Music"),
        transportFactory: { _, _ in transport }
    )

    let result = await client.testConnection()

    #expect(result.state == .online)
    #expect(result.failure == nil)
    #expect(result.capabilities?.supportsByteRangeRead == true)
    #expect(await transport.listedPaths == [""])
}

@Test func smbRemoteClientMapsUnknownErrorsWithoutCredentialLeak() async {
    let client = SMBRemoteClient(
        configuration: SMBConnectionConfiguration(host: "nas.local", share: "Music"),
        authentication: .password(username: "fixture-user", password: "fixture-password-value"),
        transportFactory: { _, _ in LeakyTransport() }
    )

    do {
        _ = try await client.list(RemotePath(displayPath: "Albums"))
        Issue.record("Expected SMBRemoteClient.list to throw")
    } catch let error as RedactableError {
        #expect(error.diagnosticsCode == "rfs.invalid_response")
        #expect(!error.redactedDebugDescription.contains("fixture-password-value"))
        #expect(!error.redactedDebugDescription.contains("fixture-user"))
        #expect(!error.redactedDebugDescription.contains("nas.local"))
    } catch {
        Issue.record("Expected a redaction-safe error")
    }
}

private actor MockSMBTransport: SMBRemoteTransport {
    private(set) var listedPaths: [String] = []
    private let fileData = Data("hello world".utf8)

    func listDirectory(path: String) async throws -> [SMBRemoteItem] {
        listedPaths.append(path)
        guard path == "" || path == "Albums" else {
            return []
        }
        return [
            SMBRemoteItem(
                name: "Song.mp3",
                kind: .file,
                size: Int64(fileData.count),
                modifiedAt: Date(timeIntervalSince1970: 1_234)
            )
        ]
    }

    func metadata(path: String) async throws -> SMBRemoteMetadata {
        #expect(path == "Albums/Song.mp3")
        return SMBRemoteMetadata(
            kind: .file,
            size: Int64(fileData.count),
            modifiedAt: Date(timeIntervalSince1970: 1_234)
        )
    }

    func read(path: String, offset: Int64, length: Int64) async throws -> Data {
        #expect(path == "Albums/Song.mp3")
        let lower = Int(offset)
        let upper = min(fileData.count, lower + Int(length))
        return fileData.subdata(in: lower..<upper)
    }

    func download(path: String, to localURL: URL, progress: ProgressSink?) async throws {
        #expect(path == "Albums/Song.mp3")
        try fileData.write(to: localURL, options: .atomic)
        await progress?(TransferProgress(completedBytes: Int64(fileData.count), totalBytes: Int64(fileData.count)))
    }
}

private struct LeakyTransport: SMBRemoteTransport {
    func listDirectory(path: String) async throws -> [SMBRemoteItem] {
        throw LeakyError()
    }

    func metadata(path: String) async throws -> SMBRemoteMetadata {
        throw LeakyError()
    }

    func read(path: String, offset: Int64, length: Int64) async throws -> Data {
        throw LeakyError()
    }

    func download(path: String, to localURL: URL, progress: ProgressSink?) async throws {
        throw LeakyError()
    }
}

private struct LeakyError: Error, CustomStringConvertible, Sendable {
    var description: String {
        "smb://fixture-user:fixture-password-value@nas.local/Music"
    }
}

private actor ProgressCollector {
    private(set) var events: [TransferProgress] = []

    func append(_ progress: TransferProgress) {
        events.append(progress)
    }
}
