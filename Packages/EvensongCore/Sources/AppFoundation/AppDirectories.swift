import Foundation

public struct AppDirectories: Sendable {
    public let caches: URL
    public let documents: URL

    public init(
        caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
        documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    ) {
        self.caches = caches
        self.documents = documents
    }

    public var mediaCache: URL {
        caches.appendingPathComponent("MediaCache", isDirectory: true)
    }
}
