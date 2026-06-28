import Foundation
import BetterStreamingDomain
import RemoteFileSystem

public enum CachePriority: String, Codable, Sendable {
    case userInitiated
    case playback
    case prefetch
    case maintenance
}

public struct CacheJobID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct CacheRequest: Sendable, Equatable {
    public var items: [MediaItemID]
    public var requiredBy: CacheRequiredBy
    public var priority: CachePriority

    public init(
        items: [MediaItemID],
        requiredBy: CacheRequiredBy,
        priority: CachePriority
    ) {
        self.items = items
        self.requiredBy = requiredBy
        self.priority = priority
    }
}

public enum CacheUnavailableReason: String, Codable, Sendable {
    case sourceOffline
    case notCached
    case downloadFailed
    case fileMissing
    case staleAndRemoteUnavailable
}

public enum PlayableAsset: Sendable, Equatable {
    case localFile(URL)
    case requiresStream(MediaItemID)
    case unavailable(CacheUnavailableReason)
}

public struct ByteProgress: Hashable, Codable, Sendable {
    public var completedBytes: Int64
    public var totalBytes: Int64?

    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = totalBytes.map { max(0, $0) }
    }

    public var remainingBytes: Int64? {
        totalBytes.map { max(0, $0 - completedBytes) }
    }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else {
            return nil
        }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    public var isComplete: Bool {
        guard let totalBytes else {
            return false
        }
        return completedBytes >= totalBytes
    }
}

public struct ByteRange: Hashable, Codable, Sendable {
    public var lowerBound: Int64
    public var upperBound: Int64

    public init(_ range: Range<Int64>) {
        self.init(lowerBound: range.lowerBound, upperBound: range.upperBound)
    }

    public init(lowerBound: Int64, upperBound: Int64) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var range: Range<Int64> {
        lowerBound..<upperBound
    }

    public var count: Int64 {
        max(0, upperBound - lowerBound)
    }

    public var isValid: Bool {
        lowerBound >= 0 && upperBound >= lowerBound
    }
}

public struct CacheKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}

public struct CachePathResolver: Sendable {
    public var rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public func key(for identity: RemoteItemIdentity) -> CacheKey {
        let signature = [
            identity.sourceID.rawValue.uuidString.lowercased(),
            identity.shareID.rawValue.uuidString.lowercased(),
            identity.path.normalizedPath,
            identity.remoteFileID?.rawValue ?? "",
            identity.size.map(String.init) ?? "",
            identity.modifiedAt.map { String(Int64($0.timeIntervalSince1970 * 1_000)) } ?? ""
        ].joined(separator: "\u{1F}")

        return CacheKey(Self.stableHash(signature))
    }

    public func completeFileURL(for identity: RemoteItemIdentity) -> URL {
        let key = key(for: identity)
        return completeFileURL(for: key, displayPath: identity.path.displayPath)
    }

    public func completeFileURL(for key: CacheKey, displayPath: String) -> URL {
        let shard = String(key.rawValue.prefix(2))
        let fileName = "\(key.rawValue).\(Self.safeExtension(from: displayPath))"
        return rootDirectory
            .appendingPathComponent("complete", isDirectory: true)
            .appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    public func temporaryFileURL(for reservationID: UUID, identity: RemoteItemIdentity) -> URL {
        let key = key(for: identity)
        let fileName = "\(reservationID.uuidString.lowercased())-\(key.rawValue).partial"
        return rootDirectory
            .appendingPathComponent("partial", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    public func byteCacheURL(for identity: RemoteItemIdentity, range: ByteRange) -> URL {
        let key = key(for: identity)
        let shard = String(key.rawValue.prefix(2))
        let fileName = "\(key.rawValue)-\(range.lowerBound)-\(range.upperBound).chunk"
        return rootDirectory
            .appendingPathComponent("bytes", isDirectory: true)
            .appendingPathComponent(shard, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func safeExtension(from displayPath: String) -> String {
        let ext = URL(fileURLWithPath: displayPath).pathExtension.lowercased()
        let scalarSet = CharacterSet.alphanumerics
        let filtered = ext.unicodeScalars.filter { scalarSet.contains($0) }
        let value = String(String.UnicodeScalarView(filtered)).prefix(16)
        return value.isEmpty ? "bin" : String(value)
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}

public struct CacheRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var mediaItemID: MediaItemID
    public var identity: RemoteItemIdentity?
    public var state: CacheState
    public var localFileURL: URL?
    public var bytesTotal: Int64?
    public var bytesDone: Int64
    public var requiredBy: Set<CacheRequiredBy>
    public var lastPlayedAt: Date?
    public var lastVerifiedAt: Date?
    public var failureCode: String?

    public init(
        id: UUID = UUID(),
        mediaItemID: MediaItemID,
        identity: RemoteItemIdentity? = nil,
        state: CacheState,
        localFileURL: URL? = nil,
        bytesTotal: Int64? = nil,
        bytesDone: Int64 = 0,
        requiredBy: Set<CacheRequiredBy> = [],
        lastPlayedAt: Date? = nil,
        lastVerifiedAt: Date? = nil,
        failureCode: String? = nil
    ) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.identity = identity
        self.state = state
        self.localFileURL = localFileURL
        self.bytesTotal = bytesTotal
        self.bytesDone = max(0, bytesDone)
        self.requiredBy = requiredBy
        self.lastPlayedAt = lastPlayedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.failureCode = failureCode
    }

    public init(
        id mediaItemID: MediaItemID,
        localURL: URL? = nil,
        state: CacheState,
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil
    ) {
        self.init(
            mediaItemID: mediaItemID,
            state: state,
            localFileURL: localURL,
            bytesTotal: totalBytes,
            bytesDone: completedBytes
        )
    }

    public var localURL: URL? {
        get { localFileURL }
        set { localFileURL = newValue }
    }

    public var completedBytes: Int64 {
        get { bytesDone }
        set { bytesDone = max(0, newValue) }
    }

    public var totalBytes: Int64? {
        get { bytesTotal }
        set { bytesTotal = newValue.map { max(0, $0) } }
    }

    public var progress: ByteProgress {
        ByteProgress(completedBytes: bytesDone, totalBytes: bytesTotal)
    }
}

public struct CacheReservation: Hashable, Codable, Sendable {
    public let id: UUID
    public let mediaItemID: MediaItemID
    public let identity: RemoteItemIdentity
    public let temporaryURL: URL
    public let finalURL: URL
    public let priority: CachePriority
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        mediaItemID: MediaItemID,
        identity: RemoteItemIdentity,
        temporaryURL: URL,
        finalURL: URL,
        priority: CachePriority,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mediaItemID = mediaItemID
        self.identity = identity
        self.temporaryURL = temporaryURL
        self.finalURL = finalURL
        self.priority = priority
        self.createdAt = createdAt
    }
}

public enum CacheEvent: Sendable, Equatable {
    case jobQueued(CacheJobID, CacheRequest)
    case recordChanged(CacheRecord)
    case progress(MediaItemID, ByteProgress)
    case completed(MediaItemID, URL)
    case failed(MediaItemID, String)
}

public enum CacheManagerError: RedactableError, Equatable {
    case missingIdentity(MediaItemID)
    case notCached(MediaItemID)
    case fileMissing(MediaItemID)
    case reservationNotFound(UUID)
    case invalidByteRange(ByteRange)
    case stateConflict(MediaItemID)
    case fileSystemFailure(code: String)

    public var userMessage: String {
        switch self {
        case .missingIdentity:
            return "The cache entry is missing its media identity."
        case .notCached:
            return "This item is not cached."
        case .fileMissing:
            return "The cached file is missing."
        case .reservationNotFound:
            return "The cache reservation could not be found."
        case .invalidByteRange:
            return "The requested byte range is invalid."
        case .stateConflict:
            return "The cache entry is already being updated."
        case .fileSystemFailure:
            return "The cache could not update local files."
        }
    }

    public var diagnosticsCode: String {
        switch self {
        case .missingIdentity: return "cache.missing_identity"
        case .notCached: return "cache.not_cached"
        case .fileMissing: return "cache.file_missing"
        case .reservationNotFound: return "cache.reservation_not_found"
        case .invalidByteRange: return "cache.invalid_byte_range"
        case .stateConflict: return "cache.state_conflict"
        case .fileSystemFailure: return "cache.file_system_failure"
        }
    }

    public var redactedDebugDescription: String {
        switch self {
        case .missingIdentity(let id):
            return "Missing identity for media item \(id.rawValue.uuidString)"
        case .notCached(let id):
            return "Media item is not cached: \(id.rawValue.uuidString)"
        case .fileMissing(let id):
            return "Cached file missing for media item \(id.rawValue.uuidString)"
        case .reservationNotFound(let id):
            return "Cache reservation not found: \(id.uuidString)"
        case .invalidByteRange(let range):
            return "Invalid byte range \(range.lowerBound)..<\(range.upperBound)"
        case .stateConflict(let id):
            return "Conflicting cache update for media item \(id.rawValue.uuidString)"
        case .fileSystemFailure(let code):
            return "Cache filesystem failure: \(code)"
        }
    }
}

public protocol CacheManaging: Sendable {
    func record(for itemID: MediaItemID) async throws -> CacheRecord?
    func playableAsset(for mediaItemID: MediaItemID, offlineMode: Bool) async throws -> PlayableAsset
    func localPlayableURL(for itemID: MediaItemID) async throws -> URL

    func pin(_ request: CacheRequest) async throws -> CacheJobID
    func unpin(mediaItemID: MediaItemID, requiredBy: CacheRequiredBy) async throws
    func ensureCompleteFile(for mediaItemID: MediaItemID, priority: CachePriority) async throws -> URL

    func reserveCompleteFile(
        for mediaItemID: MediaItemID,
        identity: RemoteItemIdentity,
        requiredBy: CacheRequiredBy,
        expectedBytes: Int64?,
        priority: CachePriority
    ) async throws -> CacheReservation
    func updateProgress(for reservationID: UUID, completedBytes: Int64, totalBytes: Int64?) async throws
    func completeReservation(_ reservationID: UUID) async throws -> CacheRecord
    func failReservation(_ reservationID: UUID, code: String) async

    func downloadCompleteFile(
        for mediaItemID: MediaItemID,
        identity: RemoteItemIdentity,
        from remote: any RemoteFileSystemClient,
        requiredBy: CacheRequiredBy,
        priority: CachePriority
    ) async throws -> URL

    func readCachedBytes(for mediaItemID: MediaItemID, range: Range<Int64>) async throws -> Data?
    func storeCachedBytes(for mediaItemID: MediaItemID, range: Range<Int64>, data: Data) async throws

    func events(for jobID: CacheJobID) async -> AsyncStream<CacheEvent>
    func enforceQuota() async throws
}

public actor FileBackedCacheManager: CacheManaging {
    private let pathResolver: CachePathResolver
    private var recordsByMediaItemID: [MediaItemID: CacheRecord]
    private var reservationsByID: [UUID: CacheReservation] = [:]
    private var jobItemsByID: [CacheJobID: Set<MediaItemID>] = [:]
    private var eventContinuationsByJobID: [CacheJobID: [UUID: AsyncStream<CacheEvent>.Continuation]] = [:]

    public init(rootDirectory: URL, records: [CacheRecord] = []) {
        self.pathResolver = CachePathResolver(rootDirectory: rootDirectory)
        self.recordsByMediaItemID = Dictionary(uniqueKeysWithValues: records.map { ($0.mediaItemID, $0) })
    }

    public init(pathResolver: CachePathResolver, records: [CacheRecord] = []) {
        self.pathResolver = pathResolver
        self.recordsByMediaItemID = Dictionary(uniqueKeysWithValues: records.map { ($0.mediaItemID, $0) })
    }

    public func record(for itemID: MediaItemID) async throws -> CacheRecord? {
        recordsByMediaItemID[itemID]
    }

    public func playableAsset(for mediaItemID: MediaItemID, offlineMode: Bool) async throws -> PlayableAsset {
        guard let record = recordsByMediaItemID[mediaItemID] else {
            return offlineMode ? .unavailable(.notCached) : .requiresStream(mediaItemID)
        }

        switch record.state {
        case .cached:
            guard let localFileURL = record.localFileURL else {
                return .unavailable(.fileMissing)
            }
            return FileManager.default.fileExists(atPath: localFileURL.path)
                ? .localFile(localFileURL)
                : .unavailable(.fileMissing)
        case .failed:
            return .unavailable(.downloadFailed)
        case .stale:
            return offlineMode ? .unavailable(.staleAndRemoteUnavailable) : .requiresStream(mediaItemID)
        case .evicted:
            return offlineMode ? .unavailable(.fileMissing) : .requiresStream(mediaItemID)
        case .remoteOnly, .queued, .downloading, .prefetched:
            return offlineMode ? .unavailable(.notCached) : .requiresStream(mediaItemID)
        }
    }

    public func localPlayableURL(for itemID: MediaItemID) async throws -> URL {
        let asset = try await playableAsset(for: itemID, offlineMode: true)
        guard case .localFile(let url) = asset else {
            if case .unavailable(.fileMissing) = asset {
                throw CacheManagerError.fileMissing(itemID)
            }
            throw CacheManagerError.notCached(itemID)
        }
        return url
    }

    public func pin(_ request: CacheRequest) async throws -> CacheJobID {
        let jobID = CacheJobID()
        jobItemsByID[jobID] = Set(request.items)

        for itemID in request.items {
            var record = recordsByMediaItemID[itemID] ?? CacheRecord(
                mediaItemID: itemID,
                state: .queued
            )
            record.requiredBy.insert(request.requiredBy)
            if record.state == .remoteOnly || record.state == .evicted {
                record.state = .queued
            }
            recordsByMediaItemID[itemID] = record
            emit(.recordChanged(record), for: itemID)
        }

        emit(.jobQueued(jobID, request), to: jobID)
        return jobID
    }

    public func unpin(mediaItemID: MediaItemID, requiredBy: CacheRequiredBy) async throws {
        guard var record = recordsByMediaItemID[mediaItemID] else {
            return
        }
        record.requiredBy.remove(requiredBy)
        if record.requiredBy.isEmpty, record.state == .queued {
            record.state = .remoteOnly
        }
        recordsByMediaItemID[mediaItemID] = record
        emit(.recordChanged(record), for: mediaItemID)
    }

    public func ensureCompleteFile(for mediaItemID: MediaItemID, priority: CachePriority) async throws -> URL {
        try await localPlayableURL(for: mediaItemID)
    }

    public func reserveCompleteFile(
        for mediaItemID: MediaItemID,
        identity: RemoteItemIdentity,
        requiredBy: CacheRequiredBy = .manual,
        expectedBytes: Int64? = nil,
        priority: CachePriority = .playback
    ) async throws -> CacheReservation {
        if let existing = recordsByMediaItemID[mediaItemID], existing.state == .downloading {
            throw CacheManagerError.stateConflict(mediaItemID)
        }

        let reservationID = UUID()
        let temporaryURL = pathResolver.temporaryFileURL(for: reservationID, identity: identity)
        let finalURL = pathResolver.completeFileURL(for: identity)
        try createDirectoryIfNeeded(at: temporaryURL.deletingLastPathComponent())
        try createDirectoryIfNeeded(at: finalURL.deletingLastPathComponent())

        let reservation = CacheReservation(
            id: reservationID,
            mediaItemID: mediaItemID,
            identity: identity,
            temporaryURL: temporaryURL,
            finalURL: finalURL,
            priority: priority
        )
        reservationsByID[reservationID] = reservation

        var requiredBySet = recordsByMediaItemID[mediaItemID]?.requiredBy ?? []
        requiredBySet.insert(requiredBy)
        let record = CacheRecord(
            mediaItemID: mediaItemID,
            identity: identity,
            state: .downloading,
            localFileURL: temporaryURL,
            bytesTotal: expectedBytes ?? identity.size,
            bytesDone: 0,
            requiredBy: requiredBySet
        )
        recordsByMediaItemID[mediaItemID] = record
        emit(.recordChanged(record), for: mediaItemID)
        emit(.progress(mediaItemID, record.progress), for: mediaItemID)

        return reservation
    }

    public func updateProgress(for reservationID: UUID, completedBytes: Int64, totalBytes: Int64?) async throws {
        guard let reservation = reservationsByID[reservationID] else {
            throw CacheManagerError.reservationNotFound(reservationID)
        }
        guard var record = recordsByMediaItemID[reservation.mediaItemID] else {
            throw CacheManagerError.missingIdentity(reservation.mediaItemID)
        }
        record.bytesDone = max(0, completedBytes)
        record.bytesTotal = totalBytes ?? record.bytesTotal
        record.state = .downloading
        recordsByMediaItemID[reservation.mediaItemID] = record
        emit(.progress(record.mediaItemID, record.progress), for: record.mediaItemID)
        emit(.recordChanged(record), for: record.mediaItemID)
    }

    public func completeReservation(_ reservationID: UUID) async throws -> CacheRecord {
        guard let reservation = reservationsByID.removeValue(forKey: reservationID) else {
            throw CacheManagerError.reservationNotFound(reservationID)
        }

        try createDirectoryIfNeeded(at: reservation.finalURL.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: reservation.finalURL.path) {
            try FileManager.default.removeItem(at: reservation.finalURL)
        }
        try FileManager.default.moveItem(at: reservation.temporaryURL, to: reservation.finalURL)
        applyPlaybackFileProtection(to: reservation.finalURL)

        let byteCount = fileSize(at: reservation.finalURL) ?? recordsByMediaItemID[reservation.mediaItemID]?.bytesTotal
        var record = recordsByMediaItemID[reservation.mediaItemID] ?? CacheRecord(
            mediaItemID: reservation.mediaItemID,
            identity: reservation.identity,
            state: .cached
        )
        record.identity = reservation.identity
        record.state = .cached
        record.localFileURL = reservation.finalURL
        record.bytesDone = byteCount ?? record.bytesDone
        record.bytesTotal = byteCount ?? record.bytesTotal
        record.lastVerifiedAt = Date()
        record.failureCode = nil
        recordsByMediaItemID[reservation.mediaItemID] = record

        emit(.recordChanged(record), for: reservation.mediaItemID)
        emit(.progress(record.mediaItemID, record.progress), for: record.mediaItemID)
        emit(.completed(record.mediaItemID, reservation.finalURL), for: record.mediaItemID)
        return record
    }

    public func failReservation(_ reservationID: UUID, code: String) async {
        guard let reservation = reservationsByID.removeValue(forKey: reservationID) else {
            return
        }

        try? FileManager.default.removeItem(at: reservation.temporaryURL)
        var record = recordsByMediaItemID[reservation.mediaItemID] ?? CacheRecord(
            mediaItemID: reservation.mediaItemID,
            identity: reservation.identity,
            state: .failed
        )
        record.identity = reservation.identity
        record.localFileURL = nil
        record.state = .failed
        record.failureCode = code
        recordsByMediaItemID[reservation.mediaItemID] = record

        emit(.recordChanged(record), for: reservation.mediaItemID)
        emit(.failed(record.mediaItemID, code), for: record.mediaItemID)
    }

    public func downloadCompleteFile(
        for mediaItemID: MediaItemID,
        identity: RemoteItemIdentity,
        from remote: any RemoteFileSystemClient,
        requiredBy: CacheRequiredBy = .manual,
        priority: CachePriority = .playback
    ) async throws -> URL {
        let reservation = try await reserveCompleteFile(
            for: mediaItemID,
            identity: identity,
            requiredBy: requiredBy,
            expectedBytes: identity.size,
            priority: priority
        )

        do {
            try await remote.download(identity.path, to: reservation.temporaryURL) { [weak self] progress in
                try? await self?.updateProgress(
                    for: reservation.id,
                    completedBytes: progress.completedBytes,
                    totalBytes: progress.totalBytes
                )
            }
            let record = try await completeReservation(reservation.id)
            guard let url = record.localFileURL else {
                throw CacheManagerError.fileMissing(mediaItemID)
            }
            return url
        } catch {
            await failReservation(reservation.id, code: redactedErrorCode(for: error))
            throw error
        }
    }

    public func readCachedBytes(for mediaItemID: MediaItemID, range: Range<Int64>) async throws -> Data? {
        let byteRange = ByteRange(range)
        guard byteRange.isValid else {
            throw CacheManagerError.invalidByteRange(byteRange)
        }
        guard let identity = recordsByMediaItemID[mediaItemID]?.identity else {
            throw CacheManagerError.missingIdentity(mediaItemID)
        }

        let url = pathResolver.byteCacheURL(for: identity, range: byteRange)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    public func storeCachedBytes(for mediaItemID: MediaItemID, range: Range<Int64>, data: Data) async throws {
        let byteRange = ByteRange(range)
        guard byteRange.isValid else {
            throw CacheManagerError.invalidByteRange(byteRange)
        }
        guard let identity = recordsByMediaItemID[mediaItemID]?.identity else {
            throw CacheManagerError.missingIdentity(mediaItemID)
        }

        let url = pathResolver.byteCacheURL(for: identity, range: byteRange)
        try createDirectoryIfNeeded(at: url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }

    public func events(for jobID: CacheJobID) async -> AsyncStream<CacheEvent> {
        AsyncStream { continuation in
            let continuationID = UUID()
            eventContinuationsByJobID[jobID, default: [:]][continuationID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeContinuation(continuationID, for: jobID)
                }
            }
        }
    }

    public func enforceQuota() async throws {
        // Quota policy lands with durable offline packs. MVP keeps pinned/cache files stable.
    }

    private func removeContinuation(_ continuationID: UUID, for jobID: CacheJobID) {
        guard var continuations = eventContinuationsByJobID[jobID], !continuations.isEmpty else {
            return
        }
        continuations[continuationID] = nil
        if continuations.isEmpty {
            eventContinuationsByJobID[jobID] = nil
        } else {
            eventContinuationsByJobID[jobID] = continuations
        }
    }

    private func emit(_ event: CacheEvent, for mediaItemID: MediaItemID) {
        for (jobID, itemIDs) in jobItemsByID where itemIDs.contains(mediaItemID) {
            emit(event, to: jobID)
        }
    }

    private func emit(_ event: CacheEvent, to jobID: CacheJobID) {
        for continuation in eventContinuationsByJobID[jobID]?.values ?? [:].values {
            continuation.yield(event)
        }
    }

    private func createDirectoryIfNeeded(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func fileSize(at url: URL) -> Int64? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return size.int64Value
    }

    private func applyPlaybackFileProtection(to url: URL) {
        #if os(iOS)
        try? (url as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        #endif
    }

    private func redactedErrorCode(for error: any Error) -> String {
        if let redactableError = error as? any RedactableError {
            return redactableError.diagnosticsCode
        }
        return String(describing: type(of: error))
    }
}
