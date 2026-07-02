import Foundation
import Testing
import EvensongDomain
import RemoteFileSystem
@testable import SMBRemote

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

    nonisolated func disconnect() {}
}

private final class LeakyTransport: SMBRemoteTransport {
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

    func disconnect() {}
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

// MARK: - Stall recovery (timeout → orphan → reconnect)

/// A read that never returns (models a wedged SMB receive with no timeout) must
/// be bounded by `withTimeout`, surface as `.timeout`, tear the transport down,
/// and let the NEXT read reconnect on a fresh transport and succeed.
@Test func smbReadTimesOutThenReconnectsOnFreshTransport() async throws {
    let made = Counter()
    let disconnects = Counter()
    let fileData = Data("hello world".utf8)
    let client = SMBRemoteClient(
        configuration: SMBConnectionConfiguration(host: "nas.local", share: "Music"),
        authentication: nil,
        transportFactory: { _, _ in
            // First connection hangs forever on read; the replacement works.
            if made.inc() == 1 {
                return HangingTransport(onDisconnect: { _ = disconnects.inc() })
            }
            return WorkingTransport(fileData: fileData)
        },
        readTimeoutNanos: 120_000_000,        // 120ms — keep the test fast
        connectTimeoutNanos: 2_000_000_000
    )

    let path = RemotePath(displayPath: "Albums/Song.mp3")

    var firstError: Error?
    do {
        _ = try await client.read(path, range: 0..<10)
    } catch {
        firstError = error
    }
    // The wedged read must surface as a timeout...
    if case .timeout? = firstError as? RemoteFileSystemError {
        // expected
    } else {
        Issue.record("expected RemoteFileSystemError.timeout, got \(String(describing: firstError))")
    }
    // ...and the dead transport must have been torn down (so it can't be reused).
    #expect(disconnects.value == 1)

    // The next read reconnects on a fresh transport and succeeds.
    let data = try await client.read(path, range: 0..<5)
    #expect(String(decoding: data, as: UTF8.self) == "hello")
    #expect(made.value == 2)
}

// MARK: - Operation serialization (FIX 6)

/// Concurrent operations on ONE client must be serialized — only a single
/// transport op in flight at a time. Without it, AVPlayer's all-to-end fill loop
/// and a scrub's bounded read race `Session.messageId` (allocated outside the
/// connection semaphore) and desync the protocol into a silent hang / garbage
/// audio (the "scrub → plays but no sound" bug). The probe records the max
/// observed overlap; the per-client FIFO lock must hold it at 1.
@Test func smbSerializesConcurrentOperations() async throws {
    let probe = ConcurrencyProbe()
    let client = SMBRemoteClient(
        configuration: SMBConnectionConfiguration(host: "nas.local", share: "Music"),
        authentication: nil,
        transportFactory: { _, _ in probe },
        readTimeoutNanos: 5_000_000_000,
        connectTimeoutNanos: 5_000_000_000
    )
    let path = RemotePath(displayPath: "Albums/Song.mp3")

    await withTaskGroup(of: Void.self) { group in
        for i in 0..<8 {
            let lower = Int64(i * 10)
            group.addTask {
                _ = try? await client.read(path, range: lower..<(lower + 5))
            }
        }
    }

    #expect(probe.maxConcurrent == 1)
    #expect(probe.totalOps == 8)
}

/// Thread-safe counter (the factory/disconnect run off-actor).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    /// Increments and returns the new value.
    @discardableResult func inc() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return n
    }
}

/// Every op hangs far longer than the injected timeout — exactly the wedge
/// `withTimeout` must escape. Only `read` is exercised by the test; the orphaned
/// sleep task is harmless and dies with the test process.
private final class HangingTransport: SMBRemoteTransport {
    let onDisconnect: @Sendable () -> Void
    init(onDisconnect: @escaping @Sendable () -> Void) { self.onDisconnect = onDisconnect }
    private static let forever: UInt64 = 60_000_000_000
    func listDirectory(path: String) async throws -> [SMBRemoteItem] {
        try await Task.sleep(nanoseconds: Self.forever); return []
    }
    func metadata(path: String) async throws -> SMBRemoteMetadata {
        try await Task.sleep(nanoseconds: Self.forever); return SMBRemoteMetadata(kind: .file)
    }
    func read(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await Task.sleep(nanoseconds: Self.forever); return Data()
    }
    func download(path: String, to localURL: URL, progress: ProgressSink?) async throws {
        try await Task.sleep(nanoseconds: Self.forever)
    }
    func disconnect() { onDisconnect() }
}

private final class WorkingTransport: SMBRemoteTransport {
    let fileData: Data
    init(fileData: Data) { self.fileData = fileData }
    func listDirectory(path: String) async throws -> [SMBRemoteItem] { [] }
    func metadata(path: String) async throws -> SMBRemoteMetadata {
        SMBRemoteMetadata(kind: .file, size: Int64(fileData.count), modifiedAt: nil)
    }
    func read(path: String, offset: Int64, length: Int64) async throws -> Data {
        let lower = Int(offset)
        let upper = min(fileData.count, lower + Int(length))
        guard lower < upper else { return Data() }
        return fileData.subdata(in: lower..<upper)
    }
    func download(path: String, to localURL: URL, progress: ProgressSink?) async throws {
        try fileData.write(to: localURL, options: .atomic)
    }
    func disconnect() {}
}

/// Records the maximum number of overlapping transport ops. Each op briefly
/// sleeps so any missing serialization surfaces as concurrency > 1.
private final class ConcurrencyProbe: SMBRemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxConcurrent = 0
    private(set) var totalOps = 0

    private func enter() {
        lock.lock(); defer { lock.unlock() }
        current += 1
        totalOps += 1
        if current > maxConcurrent { maxConcurrent = current }
    }
    private func leave() {
        lock.lock(); defer { lock.unlock() }
        current -= 1
    }

    func read(path: String, offset: Int64, length: Int64) async throws -> Data {
        enter(); defer { leave() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        return Data(count: Int(length))
    }
    func listDirectory(path: String) async throws -> [SMBRemoteItem] {
        enter(); defer { leave() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        return []
    }
    func metadata(path: String) async throws -> SMBRemoteMetadata {
        enter(); defer { leave() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        return SMBRemoteMetadata(kind: .file)
    }
    func download(path: String, to localURL: URL, progress: ProgressSink?) async throws {
        enter(); defer { leave() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    func disconnect() {}
}
