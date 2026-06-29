import AVFoundation
import BetterStreamingDomain
import Foundation
import RemoteFileSystem
import UniformTypeIdentifiers

/// Builds AVPlayerItems that stream remote files through AVAssetResourceLoader.
///
/// The player asks for byte ranges; each request is served with
/// RemoteFileSystemClient.read(path:range:) and mirrored into an on-disk partial
/// cache for repeated seeks during the session.
final class RemoteStreamingService: NSObject, @unchecked Sendable {
    private static let scheme = "betterstream"

    private let callbackQueue = DispatchQueue(label: "BetterStreaming.RemoteStreaming.loader")
    private let lock = NSLock()
    private var sessions: [String: RemoteStreamSession] = [:]
    private var activeRequests: [ObjectIdentifier: LoadingRequestBox] = [:]

    func playerItem(
        client: any RemoteFileSystemClient,
        path: RemotePath,
        metadata: RemoteMetadata,
        fallbackExtension: String,
        cacheURL: URL
    ) -> AVPlayerItem {
        let id = UUID().uuidString
        let session = RemoteStreamSession(
            id: id,
            client: client,
            path: path,
            metadata: metadata,
            fallbackExtension: fallbackExtension,
            cacheURL: cacheURL
        )

        lock.withLock { sessions[id] = session }
        let asset = AVURLAsset(url: Self.url(id: id, ext: fallbackExtension))
        asset.resourceLoader.setDelegate(self, queue: callbackQueue)
        return AVPlayerItem(asset: asset)
    }

    private static func url(id: String, ext: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = id
        components.path = "/stream.\(ext.isEmpty ? "dat" : ext)"
        return components.url!
    }

    private func session(for url: URL?) -> RemoteStreamSession? {
        guard url?.scheme == Self.scheme, let id = url?.host else { return nil }
        return lock.withLock { sessions[id] }
    }
}

extension RemoteStreamingService: AVAssetResourceLoaderDelegate {
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let session = session(for: loadingRequest.request.url) else { return false }
        let box = LoadingRequestBox(loadingRequest)
        let requestID = ObjectIdentifier(loadingRequest)
        lock.withLock { activeRequests[requestID] = box }
        Task { [weak self] in
            await session.respond(to: box)
            self?.removeActiveRequest(id: requestID)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let requestID = ObjectIdentifier(loadingRequest)
        let box = lock.withLock { activeRequests.removeValue(forKey: requestID) }
        box?.cancel()
    }

    private func removeActiveRequest(id: ObjectIdentifier) {
        lock.withLock { _ = activeRequests.removeValue(forKey: id) }
    }
}

private final class LoadingRequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
    private let lock = NSLock()
    private var cancelled = false

    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private actor RemoteStreamSession {
    private static let readChunkSize: Int64 = 512 * 1024
    private static let maxResponseBytes: Int64 = 12 * 1_024 * 1_024

    private let id: String
    private let client: any RemoteFileSystemClient
    private let path: RemotePath
    private let metadata: RemoteMetadata
    private let fallbackExtension: String
    private let cacheURL: URL
    private var cachedRanges: [Range<Int64>] = []
    #if DEBUG
    private var debugRequestCount = 0
    #endif

    init(
        id: String,
        client: any RemoteFileSystemClient,
        path: RemotePath,
        metadata: RemoteMetadata,
        fallbackExtension: String,
        cacheURL: URL
    ) {
        self.id = id
        self.client = client
        self.path = path
        self.metadata = metadata
        self.fallbackExtension = fallbackExtension
        self.cacheURL = cacheURL
    }

    func respond(to box: LoadingRequestBox) async {
        let request = box.request
        fillContentInfo(request.contentInformationRequest)

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }

        guard let length = metadata.size, length > 0 else {
            request.finishLoading(with: StreamingError.missingSize)
            return
        }

        let offset = max(dataRequest.currentOffset == 0 ? dataRequest.requestedOffset : dataRequest.currentOffset, 0)
        let requestedLength = Int64(dataRequest.requestedLength)
        let requestedUpper: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            requestedUpper = length
        } else {
            requestedUpper = min(length, offset + max(requestedLength, 0))
        }
        let upper = min(requestedUpper, offset + Self.maxResponseBytes)

        guard upper > offset else {
            request.finishLoading()
            return
        }

        #if DEBUG
        if debugRequestCount < 10 {
            debugRequestCount += 1
            print("BETTERSTREAMING_STREAM request ext=\(fallbackExtension) offset=\(offset) requested=\(requestedLength) allToEnd=\(dataRequest.requestsAllDataToEndOfResource) responseUpper=\(upper) fileLength=\(length)")
        }
        #endif

        do {
            var cursor = offset
            while cursor < upper {
                if box.isCancelled { return }
                let chunkUpper = min(upper, cursor + Self.readChunkSize)
                let range = cursor..<chunkUpper
                let data: Data
                if let cached = try cachedData(for: range) {
                    data = cached
                } else {
                    data = try await client.read(path, range: range)
                    try writeCache(data, range: range, totalLength: length)
                }
                guard !data.isEmpty else { break }
                if box.isCancelled { return }
                dataRequest.respond(with: data)
                cursor += Int64(data.count)
                if Int64(data.count) < range.count { break }
            }
            if box.isCancelled { return }
            request.finishLoading()
        } catch {
            #if DEBUG
            print("BETTERSTREAMING_STREAM error ext=\(fallbackExtension) offset=\(offset) upper=\(upper) error=\(error)")
            #endif
            if box.isCancelled { return }
            request.finishLoading(with: error)
        }
    }

    private func fillContentInfo(_ contentInfo: AVAssetResourceLoadingContentInformationRequest?) {
        guard let contentInfo else { return }
        contentInfo.isByteRangeAccessSupported = true
        contentInfo.contentLength = metadata.size ?? 0
        contentInfo.contentType = contentTypeIdentifier()
    }

    private func contentTypeIdentifier() -> String {
        let ext = fallbackExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type.identifier
        }
        if let contentType = metadata.contentType,
           let type = UTType(mimeType: contentType) {
            return type.identifier
        }
        return UTType.data.identifier
    }

    private func cachedData(for range: Range<Int64>) throws -> Data? {
        guard cachedRanges.contains(where: { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }),
              FileManager.default.fileExists(atPath: cacheURL.path) else {
            return nil
        }
        let handle = try FileHandle(forReadingFrom: cacheURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: Int(range.count))
    }

    private func writeCache(_ data: Data, range: Range<Int64>, totalLength: Int64) throws {
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: cacheURL.path) {
            FileManager.default.createFile(atPath: cacheURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: cacheURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(totalLength))
        try handle.seek(toOffset: UInt64(range.lowerBound))
        try handle.write(contentsOf: data)
        mergeCachedRange(range.lowerBound..<(range.lowerBound + Int64(data.count)))
    }

    private func mergeCachedRange(_ newRange: Range<Int64>) {
        guard !newRange.isEmpty else { return }
        cachedRanges.append(newRange)
        cachedRanges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int64>] = []
        for range in cachedRanges {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        cachedRanges = merged
    }
}

private enum StreamingError: LocalizedError {
    case missingSize

    var errorDescription: String? {
        switch self {
        case .missingSize: "Remote file size is unavailable."
        }
    }
}

private extension Range where Bound == Int64 {
    var count: Int64 { upperBound - lowerBound }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
