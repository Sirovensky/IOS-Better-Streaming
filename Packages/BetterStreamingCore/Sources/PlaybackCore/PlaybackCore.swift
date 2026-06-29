import Foundation
import BetterStreamingDomain
import CacheManager

public extension PlaybackRendererKind {
    static var avFoundation: PlaybackRendererKind { .avPlayer }
    static var vlcCompatibility: PlaybackRendererKind { .vlcKit }
}

public typealias RepeatMode = QueueRepeatMode

public enum QueueInsertionSource: Hashable, Codable, Sendable {
    case folder(FolderID, recursive: Bool)
    case playlist(PlaylistID)
    case search(String)
    case manual
}

public typealias QueueItem = QueueEntry

public extension QueueEntry {
    init(
        id: UUID = UUID(),
        mediaItemID: MediaItemID,
        title: String = "",
        source: QueueInsertionSource = .manual
    ) {
        self.init(id: id, mediaItemID: mediaItemID, title: title, subtitle: nil, duration: nil)
    }
}

public struct ShuffleSeed: Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct PlaybackQueueSeed: Sendable, Equatable {
    public var items: [QueueItem]
    public var shuffle: Bool

    public init(items: [QueueItem], shuffle: Bool = false) {
        self.items = items
        self.shuffle = shuffle
    }

    public static func items(
        _ itemIDs: [MediaItemID],
        source: QueueInsertionSource = .manual,
        shuffle: Bool = false
    ) -> PlaybackQueueSeed {
        PlaybackQueueSeed(
            items: itemIDs.map { QueueItem(mediaItemID: $0, source: source) },
            shuffle: shuffle
        )
    }
}

public typealias PlaybackQueueSnapshot = QueueSnapshot

public extension QueueSnapshot {
    init(
        id: QueueID = QueueID(),
        items: [QueueEntry] = [],
        currentIndex: Int? = nil,
        isShuffled: Bool = false,
        repeatMode: QueueRepeatMode = .off,
        savedAt: Date
    ) {
        self.init(
            id: id,
            items: items,
            currentIndex: currentIndex,
            isShuffled: isShuffled,
            repeatMode: repeatMode,
            updatedAt: savedAt
        )
        normalizeCurrentIndex()
    }

    var savedAt: Date {
        get { updatedAt }
        set { updatedAt = newValue }
    }

    var queueID: QueueID {
        get { id }
        set { id = newValue }
    }

    var shuffleEnabled: Bool {
        get { isShuffled }
        set { isShuffled = newValue }
    }

    var currentItem: QueueEntry? {
        guard let currentIndex, items.indices.contains(currentIndex) else {
            return nil
        }
        return items[currentIndex]
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    mutating func normalizeCurrentIndex() {
        if items.isEmpty {
            currentIndex = nil
        } else if let currentIndex {
            self.currentIndex = min(max(0, currentIndex), items.count - 1)
        }
    }
}

public enum PlaybackSource: Sendable, Equatable {
    case localFile(URL)
    case loopbackHTTP(URL, token: String)
}

public enum PlaybackLimitation: Hashable, Codable, Sendable {
    case noBackgroundAudio
    case noAirPlay
    case noPictureInPicture
    case requiresCompatibilityRenderer
    case unknown(String)
}

public enum ProbeResult: Sendable, Equatable {
    case supported
    case unsupported(code: String, reason: String)
    case failed(code: String)

    public var isSupported: Bool {
        if case .supported = self {
            return true
        }
        return false
    }
}

public struct PlaybackCandidate: Sendable, Equatable {
    public var itemID: MediaItemID
    public var renderer: PlaybackRendererKind
    public var source: PlaybackSource
    public var supportsBackgroundAudio: Bool
    public var supportsAirPlay: Bool
    public var supportsPiP: Bool
    public var limitations: [PlaybackLimitation]

    public init(
        itemID: MediaItemID,
        renderer: PlaybackRendererKind,
        source: PlaybackSource,
        supportsBackgroundAudio: Bool = true,
        supportsAirPlay: Bool = true,
        supportsPiP: Bool = false,
        limitations: [PlaybackLimitation] = []
    ) {
        self.itemID = itemID
        self.renderer = renderer
        self.source = source
        self.supportsBackgroundAudio = supportsBackgroundAudio
        self.supportsAirPlay = supportsAirPlay
        self.supportsPiP = supportsPiP
        self.limitations = limitations
    }
}

public protocol PlaybackRenderer: Sendable {
    var kind: PlaybackRendererKind { get }

    func probe(_ source: PlaybackSource) async -> ProbeResult
    func prepare(_ candidate: PlaybackCandidate) async throws
    func play() async
    func pause() async
    func seek(to time: TimeInterval) async throws
    func stop() async
}

public enum PlaybackTransportState: String, Codable, Sendable {
    case idle
    case preparing
    case playing
    case paused
    case buffering
    case failed
}

public enum PlaybackEvent: Sendable, Equatable {
    case queueChanged(PlaybackQueueSnapshot)
    case nowPlayingChanged(MediaItemID?)
    case stateChanged(PlaybackTransportState)
    case elapsedTimeChanged(TimeInterval)
    case failed(MediaItemID, PlaybackError)
}

public enum PlaybackAdvanceReason: String, Codable, Sendable {
    case userInitiated
    case itemFinished
}

public enum PlaybackControllerError: RedactableError, Equatable {
    case emptyQueue
    case invalidQueueIndex
    case rendererUnavailable

    public var userMessage: String {
        switch self {
        case .emptyQueue:
            return "The playback queue is empty."
        case .invalidQueueIndex:
            return "The playback queue is out of date."
        case .rendererUnavailable:
            return "No playback renderer is available."
        }
    }

    public var diagnosticsCode: String {
        switch self {
        case .emptyQueue: return "playback.empty_queue"
        case .invalidQueueIndex: return "playback.invalid_queue_index"
        case .rendererUnavailable: return "playback.renderer_unavailable"
        }
    }

    public var redactedDebugDescription: String {
        diagnosticsCode
    }
}

public protocol PlaybackControlling: Sendable {
    func replaceQueue(_ snapshot: PlaybackQueueSnapshot) async throws
    func load(_ seed: PlaybackQueueSeed, startAt: MediaItemID?) async throws
    func play() async throws
    func pause() async
    func togglePlayPause() async throws
    func seek(to time: TimeInterval) async throws
    func stop() async
    func skipToNext() async throws
    func skipToPrevious() async throws

    func playNext(_ items: [MediaItemID]) async throws
    func append(_ items: [MediaItemID]) async throws
    func reorder(fromOffsets: IndexSet, toOffset: Int) async throws
    func clearQueue() async throws
    func setShuffleEnabled(_ enabled: Bool) async throws
    func setRepeatMode(_ mode: RepeatMode) async throws

    func snapshot() async -> PlaybackQueueSnapshot
    func transportState() async -> PlaybackTransportState
    func events() async -> AsyncStream<PlaybackEvent>
}

public actor PlaybackController: PlaybackControlling {
    private var queueSnapshot: PlaybackQueueSnapshot
    private var state: PlaybackTransportState = .idle
    private var elapsedTime: TimeInterval = 0
    private let shuffleSeed: ShuffleSeed
    private let cache: (any CacheManaging)?
    private var renderersByKind: [PlaybackRendererKind: any PlaybackRenderer]
    private var eventContinuations: [UUID: AsyncStream<PlaybackEvent>.Continuation] = [:]

    public init(
        snapshot: PlaybackQueueSnapshot = PlaybackQueueSnapshot(),
        shuffleSeed: ShuffleSeed = ShuffleSeed(0xB377_5EED),
        cache: (any CacheManaging)? = nil,
        renderers: [any PlaybackRenderer] = []
    ) {
        self.queueSnapshot = snapshot
        self.shuffleSeed = shuffleSeed
        self.cache = cache
        self.renderersByKind = Dictionary(uniqueKeysWithValues: renderers.map { ($0.kind, $0) })
    }

    public func replaceQueue(_ snapshot: PlaybackQueueSnapshot) async throws {
        queueSnapshot = snapshot
        queueSnapshot.normalizeCurrentIndex()
        queueSnapshot.savedAt = Date()
        if queueSnapshot.currentIndex == nil, !queueSnapshot.items.isEmpty {
            queueSnapshot.currentIndex = 0
        }
        emit(.queueChanged(queueSnapshot))
        emit(.nowPlayingChanged(queueSnapshot.currentItem?.mediaItemID))
    }

    public func load(_ seed: PlaybackQueueSeed, startAt: MediaItemID? = nil) async throws {
        var items = seed.items
        if seed.shuffle {
            items = Self.deterministicallyShuffled(items, seed: shuffleSeed)
        }

        let currentIndex: Int?
        if let startAt {
            currentIndex = items.firstIndex { $0.mediaItemID == startAt } ?? (items.isEmpty ? nil : 0)
        } else {
            currentIndex = items.isEmpty ? nil : 0
        }

        queueSnapshot = PlaybackQueueSnapshot(
            id: QueueID(),
            items: items,
            currentIndex: currentIndex,
            isShuffled: seed.shuffle,
            repeatMode: queueSnapshot.repeatMode
        )
        emit(.queueChanged(queueSnapshot))
        emit(.nowPlayingChanged(queueSnapshot.currentItem?.mediaItemID))
    }

    public func play() async throws {
        guard let item = queueSnapshot.currentItem else {
            throw PlaybackControllerError.emptyQueue
        }

        state = .preparing
        emit(.stateChanged(state))

        guard let renderer = try await prepareRenderer(for: item) else {
            // No renderer was available/prepared for this item. Do not report a
            // fake `.playing` state with zero renderers: surface the failure.
            let error = PlaybackError.sourceUnavailable(item.mediaItemID)
            state = .failed
            emit(.stateChanged(state))
            emit(.failed(item.mediaItemID, error))
            throw error
        }

        await renderer.play()

        state = .playing
        emit(.stateChanged(state))
        emit(.nowPlayingChanged(item.mediaItemID))
    }

    public func pause() async {
        for renderer in renderersByKind.values {
            await renderer.pause()
        }
        state = .paused
        emit(.stateChanged(state))
    }

    public func togglePlayPause() async throws {
        switch state {
        case .playing, .buffering:
            await pause()
        default:
            try await play()
        }
    }

    public func seek(to time: TimeInterval) async throws {
        elapsedTime = max(0, time)
        for renderer in renderersByKind.values {
            try await renderer.seek(to: elapsedTime)
        }
        emit(.elapsedTimeChanged(elapsedTime))
    }

    public func stop() async {
        for renderer in renderersByKind.values {
            await renderer.stop()
        }
        elapsedTime = 0
        state = .idle
        emit(.elapsedTimeChanged(elapsedTime))
        emit(.stateChanged(state))
    }

    public func skipToNext() async throws {
        try await advance(reason: .userInitiated, direction: .forward)
    }

    public func skipToPrevious() async throws {
        try await advance(reason: .userInitiated, direction: .backward)
    }

    public func finishCurrentItem() async throws {
        try await advance(reason: .itemFinished, direction: .forward)
    }

    public func playNext(_ items: [MediaItemID]) async throws {
        guard !items.isEmpty else {
            return
        }

        let queueItems = items.map { QueueItem(mediaItemID: $0, source: .manual) }
        let insertionIndex = (queueSnapshot.currentIndex ?? -1) + 1
        queueSnapshot.items.insert(contentsOf: queueItems, at: min(max(0, insertionIndex), queueSnapshot.items.count))
        if queueSnapshot.currentIndex == nil {
            queueSnapshot.currentIndex = 0
        }
        queueSnapshot.savedAt = Date()
        emit(.queueChanged(queueSnapshot))
    }

    public func append(_ items: [MediaItemID]) async throws {
        guard !items.isEmpty else {
            return
        }

        queueSnapshot.items.append(contentsOf: items.map { QueueItem(mediaItemID: $0, source: .manual) })
        if queueSnapshot.currentIndex == nil {
            queueSnapshot.currentIndex = 0
            emit(.nowPlayingChanged(queueSnapshot.currentItem?.mediaItemID))
        }
        queueSnapshot.savedAt = Date()
        emit(.queueChanged(queueSnapshot))
    }

    public func reorder(fromOffsets: IndexSet, toOffset: Int) async throws {
        guard !queueSnapshot.items.isEmpty else {
            return
        }
        let currentItemID = queueSnapshot.currentItem?.id
        queueSnapshot.items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        if let currentItemID {
            queueSnapshot.currentIndex = queueSnapshot.items.firstIndex { $0.id == currentItemID }
        }
        queueSnapshot.normalizeCurrentIndex()
        queueSnapshot.savedAt = Date()
        emit(.queueChanged(queueSnapshot))
    }

    public func clearQueue() async throws {
        queueSnapshot = PlaybackQueueSnapshot(
            id: QueueID(),
            repeatMode: queueSnapshot.repeatMode
        )
        elapsedTime = 0
        state = .idle
        emit(.queueChanged(queueSnapshot))
        emit(.nowPlayingChanged(nil))
        emit(.stateChanged(state))
    }

    public func setShuffleEnabled(_ enabled: Bool) async throws {
        guard queueSnapshot.isShuffled != enabled else {
            return
        }

        let currentItemID = queueSnapshot.currentItem?.id
        if enabled {
            queueSnapshot.items = Self.deterministicallyShuffled(queueSnapshot.items, seed: shuffleSeed)
        }
        queueSnapshot.isShuffled = enabled
        if let currentItemID {
            queueSnapshot.currentIndex = queueSnapshot.items.firstIndex { $0.id == currentItemID }
        }
        queueSnapshot.normalizeCurrentIndex()
        queueSnapshot.savedAt = Date()
        emit(.queueChanged(queueSnapshot))
    }

    public func setRepeatMode(_ mode: RepeatMode) async throws {
        queueSnapshot.repeatMode = mode
        queueSnapshot.savedAt = Date()
        emit(.queueChanged(queueSnapshot))
    }

    public func snapshot() async -> PlaybackQueueSnapshot {
        queueSnapshot
    }

    public func transportState() async -> PlaybackTransportState {
        state
    }

    public func events() async -> AsyncStream<PlaybackEvent> {
        AsyncStream { continuation in
            let id = UUID()
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeContinuation(id)
                }
            }
        }
    }

    private enum AdvanceDirection {
        case forward
        case backward
    }

    private func advance(reason: PlaybackAdvanceReason, direction: AdvanceDirection) async throws {
        guard let currentIndex = queueSnapshot.currentIndex else {
            throw PlaybackControllerError.emptyQueue
        }

        let nextIndex: Int?
        switch direction {
        case .forward:
            nextIndex = Self.nextIndex(
                from: currentIndex,
                count: queueSnapshot.items.count,
                repeatMode: queueSnapshot.repeatMode,
                reason: reason
            )
        case .backward:
            nextIndex = Self.previousIndex(
                from: currentIndex,
                count: queueSnapshot.items.count,
                repeatMode: queueSnapshot.repeatMode
            )
        }

        guard let nextIndex else {
            await stop()
            queueSnapshot.currentIndex = nil
            queueSnapshot.savedAt = Date()
            emit(.queueChanged(queueSnapshot))
            emit(.nowPlayingChanged(nil))
            return
        }

        queueSnapshot.currentIndex = nextIndex
        queueSnapshot.savedAt = Date()
        elapsedTime = 0
        emit(.queueChanged(queueSnapshot))
        emit(.elapsedTimeChanged(elapsedTime))
        emit(.nowPlayingChanged(queueSnapshot.currentItem?.mediaItemID))

        if state == .playing || state == .buffering || state == .preparing {
            try await play()
        }
    }

    private func prepareRenderer(for item: QueueItem) async throws -> (any PlaybackRenderer)? {
        guard !renderersByKind.isEmpty else {
            return nil
        }

        let source = try await playbackSource(for: item.mediaItemID)
        let candidateKinds: [PlaybackRendererKind] = [.avFoundation, .vlcCompatibility]

        for kind in candidateKinds {
            guard let renderer = renderersByKind[kind] else {
                continue
            }
            let result = await renderer.probe(source)
            guard result.isSupported else {
                continue
            }
            let candidate = PlaybackCandidate(
                itemID: item.mediaItemID,
                renderer: kind,
                source: source,
                limitations: kind == .vlcCompatibility ? [.requiresCompatibilityRenderer] : []
            )
            try await renderer.prepare(candidate)
            return renderer
        }

        throw PlaybackError.unsupportedFormat(item.mediaItemID, reason: "No renderer accepted the playback source.")
    }

    private func playbackSource(for itemID: MediaItemID) async throws -> PlaybackSource {
        guard let cache else {
            throw PlaybackControllerError.rendererUnavailable
        }

        let asset = try await cache.playableAsset(for: itemID, offlineMode: false)
        switch asset {
        case .localFile(let url):
            return .localFile(url)
        case .requiresStream:
            throw PlaybackError.cacheRequired(itemID)
        case .unavailable(let reason):
            switch reason {
            case .downloadFailed:
                throw PlaybackError.sourceUnavailable(itemID)
            case .notCached, .sourceOffline, .fileMissing, .staleAndRemoteUnavailable:
                throw PlaybackError.cacheRequired(itemID)
            }
        }
    }

    private func emit(_ event: PlaybackEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }

    public static func nextIndex(
        from currentIndex: Int,
        count: Int,
        repeatMode: RepeatMode,
        reason: PlaybackAdvanceReason
    ) -> Int? {
        guard count > 0, currentIndex >= 0, currentIndex < count else {
            return nil
        }

        if repeatMode == .one, reason == .itemFinished {
            return currentIndex
        }

        let next = currentIndex + 1
        if next < count {
            return next
        }
        return repeatMode == .all ? 0 : nil
    }

    public static func previousIndex(
        from currentIndex: Int,
        count: Int,
        repeatMode: RepeatMode
    ) -> Int? {
        guard count > 0, currentIndex >= 0, currentIndex < count else {
            return nil
        }

        let previous = currentIndex - 1
        if previous >= 0 {
            return previous
        }
        return repeatMode == .all ? count - 1 : 0
    }

    public static func deterministicallyShuffled(_ items: [QueueItem], seed: ShuffleSeed) -> [QueueItem] {
        items
            .enumerated()
            .sorted { lhs, rhs in
                let lhsKey = stableShuffleKey(for: lhs.element.id, seed: seed)
                let rhsKey = stableShuffleKey(for: rhs.element.id, seed: seed)
                if lhsKey == rhsKey {
                    return lhs.offset < rhs.offset
                }
                return lhsKey < rhsKey
            }
            .map(\.element)
    }

    private static func stableShuffleKey(for id: UUID, seed: ShuffleSeed) -> UInt64 {
        var hash = seed.rawValue ^ 14_695_981_039_346_656_037
        for byte in id.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }
}

private extension Array {
    mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let validOffsets = offsets.filter { indices.contains($0) }
        guard !validOffsets.isEmpty else {
            return
        }

        let moving = validOffsets.map { self[$0] }
        for offset in validOffsets.sorted(by: >) {
            remove(at: offset)
        }

        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let adjustedDestination = destination - removedBeforeDestination
        insert(contentsOf: moving, at: Swift.min(Swift.max(0, adjustedDestination), count))
    }
}
