import AVFoundation
import BetterStreamingDomain
import Foundation
import RemoteFileSystem
import UniformTypeIdentifiers

/// Builds AVPlayerItems that stream remote files through AVAssetResourceLoader.
///
/// The player asks for byte ranges; each request is served with
/// RemoteFileSystemClient.read(path:range:) and mirrored into an on-disk partial
/// cache for repeated seeks during the session. When a track has been streamed
/// in full it is promoted into the regular media cache so the next play (and
/// offline use) reads a complete local file.
///
/// IMPORTANT — the streaming contract:
/// AVPlayer's first request is usually `requestsAllDataToEndOfResource`. We must
/// keep serving bytes for the requested range and only call `finishLoading()`
/// once the data delivered actually reaches the requested end (the true file
/// length for an all-to-end request). Calling `finishLoading()` after serving a
/// *capped* slice tells AVPlayer the resource ends there — a false EOF — and
/// playback stops. Backpressure is AVPlayer's job: when its forward buffer is
/// full it cancels the outstanding request (`didCancel`), then re-issues at a
/// higher offset. We honour cancellation; we never cap.
final class RemoteStreamingService: NSObject, @unchecked Sendable {
    private static let scheme = "betterstream"
    /// Live AVURLAsset sessions kept addressable for the delegate. Bounded so a
    /// long listening session can't accumulate sessions (and partial files)
    /// without limit; the oldest is torn down when the cap is exceeded.
    private static let maxLiveSessions = 8

    private let callbackQueue = DispatchQueue(label: "BetterStreaming.RemoteStreaming.loader")
    private let lock = NSLock()
    private var sessions: [String: RemoteStreamSession] = [:]
    private var sessionOrder: [String] = []
    private var activeRequests: [ObjectIdentifier: LoadingRequestBox] = [:]

    func playerItem(
        client: any RemoteFileSystemClient,
        path: RemotePath,
        metadata: RemoteMetadata,
        fallbackExtension: String,
        partialCacheURL: URL,
        completeCacheURL: URL,
        onComplete: (@Sendable () async -> Void)? = nil
    ) -> AVPlayerItem {
        let id = UUID().uuidString
        let session = RemoteStreamSession(
            id: id,
            client: client,
            path: path,
            metadata: metadata,
            fallbackExtension: fallbackExtension,
            partialCacheURL: partialCacheURL,
            completeCacheURL: completeCacheURL,
            onComplete: onComplete
        )

        var evicted: [RemoteStreamSession] = []
        lock.withLock {
            sessions[id] = session
            sessionOrder.append(id)
            while sessionOrder.count > Self.maxLiveSessions {
                let oldID = sessionOrder.removeFirst()
                if let old = sessions.removeValue(forKey: oldID) { evicted.append(old) }
            }
        }
        for old in evicted { Task { await old.teardown() } }

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

    private let id: String
    private let client: any RemoteFileSystemClient
    private let path: RemotePath
    private let metadata: RemoteMetadata
    private let fallbackExtension: String
    private let partialCacheURL: URL
    private let completeCacheURL: URL
    private let onComplete: (@Sendable () async -> Void)?
    private var cachedRanges: [Range<Int64>] = []
    private var writeHandle: FileHandle?
    /// Set once the partial file has been copied into the regular media cache.
    private var promoted = false
    #if DEBUG
    private var debugRequestCount = 0
    #endif

    init(
        id: String,
        client: any RemoteFileSystemClient,
        path: RemotePath,
        metadata: RemoteMetadata,
        fallbackExtension: String,
        partialCacheURL: URL,
        completeCacheURL: URL,
        onComplete: (@Sendable () async -> Void)?
    ) {
        self.id = id
        self.client = client
        self.path = path
        self.metadata = metadata
        self.fallbackExtension = fallbackExtension
        self.partialCacheURL = partialCacheURL
        self.completeCacheURL = completeCacheURL
        self.onComplete = onComplete
    }

    /// Release the write handle and delete the session's partial scratch file.
    /// Safe even after promotion — the complete copy lives in the media cache.
    func teardown() {
        try? writeHandle?.close()
        writeHandle = nil
        try? FileManager.default.removeItem(at: partialCacheURL)
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

        // currentOffset is initialised to requestedOffset and advances as we
        // respond; start from wherever we've already delivered.
        let offset = max(dataRequest.currentOffset, 0)
        let upper: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            // Disregard requestedLength; serve to the true end of the file.
            upper = length
        } else {
            let requestedLength = Int64(dataRequest.requestedLength)
            upper = min(length, dataRequest.requestedOffset + max(requestedLength, 0))
        }

        guard upper > offset else {
            request.finishLoading()
            return
        }

        #if DEBUG
        if debugRequestCount < 10 {
            debugRequestCount += 1
            print("BETTERSTREAMING_STREAM request ext=\(fallbackExtension) offset=\(offset) upper=\(upper) allToEnd=\(dataRequest.requestsAllDataToEndOfResource) fileLength=\(length)")
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
                    let fetched = try await client.read(path, range: range)
                    if !fetched.isEmpty {
                        try writeCache(fetched, at: cursor, totalLength: length)
                    }
                    data = fetched
                }
                if box.isCancelled { return }
                guard !data.isEmpty else {
                    // EOF before reaching the requested end: the file is shorter
                    // than advertised. Surface an error rather than a false EOF.
                    request.finishLoading(with: StreamingError.shortRead)
                    return
                }
                dataRequest.respond(with: data)
                cursor += Int64(data.count)
            }
            if box.isCancelled { return }
            request.finishLoading()
            await maybePromote(totalLength: length)
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
        let ext = fallbackExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type.identifier
        }
        if let contentType = metadata.contentType,
           let type = UTType(mimeType: contentType) {
            return type.identifier
        }
        // Known fallbacks for formats whose UTI may not resolve from extension.
        switch ext {
        case "flac": return "org.xiph.flac"
        case "mp3": return UTType.mp3.identifier
        case "m4a", "aac": return UTType.mpeg4Audio.identifier
        case "wav": return UTType.wav.identifier
        case "aiff", "aif": return UTType.aiff.identifier
        default: return UTType.data.identifier
        }
    }

    private func cachedData(for range: Range<Int64>) throws -> Data? {
        guard cachedRanges.contains(where: { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }) else {
            return nil
        }
        let url: URL
        if FileManager.default.fileExists(atPath: partialCacheURL.path) {
            url = partialCacheURL
        } else if promoted, FileManager.default.fileExists(atPath: completeCacheURL.path) {
            url = completeCacheURL
        } else {
            return nil
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: Int(range.count))
    }

    private func writeCache(_ data: Data, at offset: Int64, totalLength: Int64) throws {
        guard !promoted else { return }
        let handle = try writeHandleCreatingIfNeeded(totalLength: totalLength)
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        mergeCachedRange(offset..<(offset + Int64(data.count)))
    }

    /// One long-lived write handle per session; the file is sized to its full
    /// logical length exactly once (sparse), not on every chunk write.
    private func writeHandleCreatingIfNeeded(totalLength: Int64) throws -> FileHandle {
        if let writeHandle { return writeHandle }
        let directory = partialCacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: partialCacheURL.path) {
            FileManager.default.createFile(atPath: partialCacheURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partialCacheURL)
        try handle.truncate(atOffset: UInt64(max(totalLength, 0)))
        writeHandle = handle
        return handle
    }

    /// When the whole file [0, length) has been fetched, copy the partial file
    /// into the regular media cache so the next play / offline reads a complete
    /// local file. Copy (not move) so an active session keeps reading.
    private func maybePromote(totalLength: Int64) async {
        guard !promoted, totalLength > 0 else { return }
        guard cachedRanges.count == 1,
              let only = cachedRanges.first,
              only.lowerBound <= 0,
              only.upperBound >= totalLength else { return }

        try? writeHandle?.close()
        writeHandle = nil

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: completeCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: completeCacheURL)
            try fm.copyItem(at: partialCacheURL, to: completeCacheURL)
            promoted = true
            #if DEBUG
            print("BETTERSTREAMING_STREAM promoted ext=\(fallbackExtension) bytes=\(totalLength)")
            #endif
            await onComplete?()
        } catch {
            #if DEBUG
            print("BETTERSTREAMING_STREAM promote_failed error=\(error)")
            #endif
        }
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
    case shortRead

    var errorDescription: String? {
        switch self {
        case .missingSize: "Remote file size is unavailable."
        case .shortRead: "The remote file ended before all requested data arrived."
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
