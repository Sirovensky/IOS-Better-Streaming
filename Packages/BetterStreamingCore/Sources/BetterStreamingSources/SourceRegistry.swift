import Foundation
import BetterStreamingDomain
import RemoteFileSystem

public protocol SourceRegistry: Sendable {
    func listSources() async throws -> [SourceRecord]
    func source(id: SourceID) async throws -> SourceRecord?
    func saveSource(_ draft: SourceDraft, credential: CredentialSecret?) async throws -> SourceRecord
    func updateCredential(for sourceID: SourceID, credential: CredentialSecret) async throws
    func deleteSource(_ sourceID: SourceID) async throws
    func testSource(_ sourceID: SourceID) async throws -> SourceHealthSnapshot
    func listRoots(for sourceID: SourceID) async throws -> [RemoteEntry]
    func openFileSystem(sourceID: SourceID, shareID: ShareID) async throws -> any RemoteFileSystemClient
}
