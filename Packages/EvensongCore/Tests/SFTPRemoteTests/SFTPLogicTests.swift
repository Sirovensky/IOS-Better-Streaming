import EvensongDomain
import Foundation
import RemoteFileSystem
import Testing
@testable import SFTPRemote

private func scratchStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("known_hosts_\(UUID().uuidString).json")
}

@Test func tofuFirstUseAcceptsAndRemembersTheKey() {
    let store = scratchStoreURL()
    defer { try? FileManager.default.removeItem(at: store) }

    let first = TOFUHostKeyValidator.decide(endpoint: "nas:22", fingerprint: "AAAA", storeURL: store)
    #expect(isSuccess(first))

    // A second connect with the SAME key still succeeds.
    let again = TOFUHostKeyValidator.decide(endpoint: "nas:22", fingerprint: "AAAA", storeURL: store)
    #expect(isSuccess(again))
}

@Test func tofuRejectsAChangedKey() {
    let store = scratchStoreURL()
    defer { try? FileManager.default.removeItem(at: store) }

    _ = TOFUHostKeyValidator.decide(endpoint: "nas:22", fingerprint: "AAAA", storeURL: store)
    let changed = TOFUHostKeyValidator.decide(endpoint: "nas:22", fingerprint: "BBBB", storeURL: store)
    #expect(!isSuccess(changed))
}

@Test func tofuFailsClosedWhenStoreIsUnavailable() {
    // Application Support unavailable → no insecure tmp fallback, refuse.
    let result = TOFUHostKeyValidator.decide(endpoint: "nas:22", fingerprint: "AAAA", storeURL: nil)
    #expect(!isSuccess(result))
}

@Test func tofuFailsClosedWhenStorePathIsUnwritable() {
    let unwritable = URL(fileURLWithPath: "/this/path/should/not/exist/known_hosts.json")
    let result = TOFUHostKeyValidator.decide(endpoint: "nas:22", fingerprint: "AAAA", storeURL: unwritable)
    #expect(!isSuccess(result))
}

@Test func sftpErrorTextMapsToTypedErrors() {
    let path = RemotePath(displayPath: "/x")
    #expect(mapped("Permission denied (publickey,password)", path) == .authenticationExpired)
    #expect(mapped("No such file or directory", path) == .notFound(path))
    #expect(mapped("channel closed by remote", path) == .serverDisconnected)
    #expect(mapped("something unexpected", path) == .invalidResponse)
}

private func mapped(_ text: String, _ path: RemotePath) -> RemoteFileSystemError? {
    SFTPRemoteClient.map(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: text]), path: path) as? RemoteFileSystemError
}

private func isSuccess(_ result: Result<Void, Error>) -> Bool {
    if case .success = result { return true }
    return false
}
