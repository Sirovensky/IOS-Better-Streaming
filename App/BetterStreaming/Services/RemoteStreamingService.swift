import AVFoundation
import BetterStreamingDomain
import Foundation
import os
import RemoteFileSystem
import UniformTypeIdentifiers

/// Streaming diagnostics — captured by `log stream`/Console on both device and
/// simulator (unlike `print`), so stalls can be diagnosed from real logs.
let streamLog = Logger(subsystem: "com.betterstreaming.app", category: "streaming")

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
        streamLog.info("didCancel offset=\(loadingRequest.dataRequest?.requestedOffset ?? -1)")
        #if DEBUG
        print("BETTERSTREAMING_STREAM didCancel offset=\(loadingRequest.dataRequest?.requestedOffset ?? -1)")
        #endif
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
    /// True once the partial cache file has been created+sized, so we only
    /// truncate to the full logical length once.
    private var didSizeCacheFile = false
    /// Set once the partial file has been copied into the regular media cache.
    private var promoted = false
    /// A transient remote read failure (timeout / dropped connection) retries a
    /// few times before the loading request is failed, so one hiccup doesn't end
    /// playback. The underlying client resets a wedged connection on timeout, so
    /// the retry reads through a fresh transport.
    private static let maxReadRetries = 3
    private static let retryBackoffNanos: UInt64 = 350_000_000
    /// Incremented each time an `allToEnd` fill request starts; an older fill loop
    /// stops once a newer one supersedes it. Only `allToEnd` requests participate.
    private var allToEndEpoch: UInt64 = 0

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

    /// Delete the session's partial scratch file. Safe even after promotion —
    /// the complete copy lives in the media cache.
    func teardown() {
        try? FileManager.default.removeItem(at: partialCacheURL)
    }

    func respond(to box: LoadingRequestBox) async {
        let request = box.request

        // Answer the content-information request on its OWN and finish it without
        // serving any of its (often 2-byte) dataRequest. This is what lets
        // AVPlayer learn the resource supports byte-range access and switch to
        // random-access mode, after which it issues bounded ranged requests and
        // proper seek requests. Serving the stream on this request instead keeps
        // AVPlayer in sequential mode — seeks then fail and playback stalls when
        // it needs data it hasn't streamed yet.
        if let contentInfo = request.contentInformationRequest {
            fillContentInfo(contentInfo)
            request.finishLoading()
            return
        }

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
        let isAllToEnd = dataRequest.requestsAllDataToEndOfResource
        let upper: Int64
        if isAllToEnd {
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

        // Bounded probe/seek requests are always served in full (AVPlayer keeps
        // several alive at once and needs them all — killing one stalls its byte
        // stream). But an `allToEnd` fill loop is the long-running, transport-
        // hogging one: when AVPlayer issues a NEWER allToEnd request (a reposition
        // after the first fill) and its `didCancel` for the old one doesn't fire
        // (unreliable on-device), the orphaned old loop keeps contending for the
        // one-at-a-time SMB connection and starves the new fill → stall. So an
        // allToEnd loop yields the moment a newer allToEnd request supersedes it.
        // Bounded requests neither bump nor check this, so a probe never aborts a
        // fill (which was the earlier "stall at 0:38" regression).
        let myAllToEndEpoch: UInt64
        if isAllToEnd {
            allToEndEpoch &+= 1
            myAllToEndEpoch = allToEndEpoch
        } else {
            myAllToEndEpoch = 0
        }

        streamLog.info("request ext=\(self.fallbackExtension, privacy: .public) offset=\(offset) upper=\(upper) allToEnd=\(isAllToEnd) len=\(length)")
        #if DEBUG
        print("BETTERSTREAMING_STREAM request offset=\(offset) upper=\(upper) allToEnd=\(isAllToEnd) len=\(length)")
        #endif

        var cursor = offset
        var failures = 0
        var sinceLog: Int64 = 0
        while cursor < upper {
            if box.isCancelled {
                streamLog.info("cancelled_exit reqOffset=\(offset) servedTo=\(cursor)")
                return
            }
            if isAllToEnd, myAllToEndEpoch != allToEndEpoch {
                // A newer allToEnd request took over. Finish with an error rather
                // than returning silently: if AVPlayer still needs this request
                // (it can keep several alive, and task scheduling isn't strictly
                // ordered) an unfinished request would hang forever. An error lets
                // AVPlayer re-drive; if it truly abandoned this one, the error is
                // simply ignored.
                streamLog.info("superseded reqOffset=\(offset) servedTo=\(cursor)")
                request.finishLoading(with: StreamingError.superseded)
                return
            }
            let chunkUpper = min(upper, cursor + Self.readChunkSize)
            let range = cursor..<chunkUpper
            let data: Data
            do {
                if let cached = try cachedData(for: range) {
                    data = cached
                } else {
                    let fetched = try await client.read(path, range: range)
                    if !fetched.isEmpty {
                        try writeCache(fetched, at: cursor, totalLength: length)
                    }
                    data = fetched
                }
            } catch {
                if box.isCancelled { return }
                failures += 1
                streamLog.error("read_error offset=\(cursor) attempt=\(failures) err=\(String(describing: error), privacy: .public)")
                if failures <= Self.maxReadRetries {
                    try? await Task.sleep(nanoseconds: Self.retryBackoffNanos)
                    continue   // retry the same chunk (client reconnects on disconnect)
                }
                if box.isCancelled { return }
                streamLog.error("give_up offset=\(cursor) -> finishLoading(error)")
                request.finishLoading(with: error)
                return
            }
            if box.isCancelled { return }
            if data.isEmpty {
                // A momentary empty read can be a transient SMB hiccup; retry a
                // few times before treating it as a genuinely short file (which
                // would otherwise be a false EOF and stop playback).
                failures += 1
                streamLog.error("empty_read offset=\(cursor) attempt=\(failures)")
                if failures <= Self.maxReadRetries {
                    try? await Task.sleep(nanoseconds: Self.retryBackoffNanos)
                    continue
                }
                request.finishLoading(with: StreamingError.shortRead)
                return
            }
            failures = 0
            dataRequest.respond(with: data)
            cursor += Int64(data.count)
            sinceLog += Int64(data.count)
            if sinceLog >= 4 * 1024 * 1024 {
                sinceLog = 0
                streamLog.info("served reqOffset=\(offset) cursor=\(cursor) upper=\(upper)")
            }
        }
        if box.isCancelled { return }
        request.finishLoading()
        streamLog.info("finished offset=\(offset) upper=\(upper)")
        await maybePromote(totalLength: length)
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

    /// Write one fetched chunk to the partial cache. Opens its own handle for
    /// the write (no shared long-lived handle), so AVPlayer's concurrent loading
    /// requests — which interleave on this actor at await points — can't corrupt
    /// each other's file position. The file is sized to its full logical length
    /// once, then writes go to absolute offsets.
    private func writeCache(_ data: Data, at offset: Int64, totalLength: Int64) throws {
        guard !promoted else { return }
        let fm = FileManager.default
        if !didSizeCacheFile {
            try fm.createDirectory(at: partialCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: partialCacheURL.path) {
                fm.createFile(atPath: partialCacheURL.path, contents: nil)
            }
            let sizing = try FileHandle(forWritingTo: partialCacheURL)
            try sizing.truncate(atOffset: UInt64(max(totalLength, 0)))
            try? sizing.close()
            didSizeCacheFile = true
        }
        let handle = try FileHandle(forWritingTo: partialCacheURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        mergeCachedRange(offset..<(offset + Int64(data.count)))
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

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: completeCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Copy to a temp then atomically rename into place. A direct
            // remove+copy could be interrupted (crash/kill) mid-copy, leaving a
            // truncated file that `fileExists` reports as fully cached forever.
            let tmp = completeCacheURL.appendingPathExtension("promote-part")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: partialCacheURL, to: tmp)
            try? fm.removeItem(at: completeCacheURL)
            try fm.moveItem(at: tmp, to: completeCacheURL)   // atomic rename on one volume
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
    case superseded

    var errorDescription: String? {
        switch self {
        case .missingSize: "Remote file size is unavailable."
        case .shortRead: "The remote file ended before all requested data arrived."
        case .superseded: "The request was superseded by a newer one."
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
