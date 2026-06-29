import AVFoundation
import Foundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

enum RepeatMode: String, Sendable {
    case off
    case all
    case one

    var systemImage: String {
        switch self {
        case .off, .all: "repeat"
        case .one: "repeat.1"
        }
    }
}

/// Real audio playback engine built on `AVPlayer`.
///
/// It owns the transport, the play queue (shuffle/repeat/reorder), the audio
/// session, and system media integration (lock screen / Control Center / remote
/// commands). It does NOT know where a track's bytes come from: callers inject a
/// `resolveAsset` closure that returns a local cache file or a loopback stream
/// URL. This keeps SMB credentials out of the renderer, per the architecture
/// contracts.
@Observable
@MainActor
final class PlaybackEngine {
    // MARK: Observed state

    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var shuffleEnabled = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var currentArtwork: UIImage?
    /// Set when a resolve/playback attempt fails, for surfacing in the UI.
    private(set) var lastErrorMessage: String?

    var currentTrack: Track? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var hasNext: Bool {
        repeatMode != .off || currentIndex < queue.count - 1
    }

    var hasPrevious: Bool {
        currentIndex > 0 || elapsed > 3
    }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    // MARK: Injected dependencies

    /// Resolves a fully configured player item. Used for remote range streaming.
    var resolvePlayerItem: (@MainActor (Track) async -> AVPlayerItem?)?
    /// Resolves a playable URL (local file or loopback stream) for a track.
    /// Returns nil if the track cannot currently be played (offline + uncached).
    var resolveAsset: (@MainActor (Track) async -> URL?)?
    /// Loads artwork for lock screen / Now Playing. Optional.
    var loadArtwork: (@MainActor (Track) async -> UIImage?)?
    /// Called when a track actually starts, for recency/auto-cache tracking.
    var onTrackStarted: (@MainActor (Track) -> Void)?
    /// Reports a track's real duration once the asset resolves it, so the library
    /// (which has no duration from a tag-only scan) can persist + display it.
    var onDurationResolved: (@MainActor (String, Double) -> Void)?

    // MARK: Private

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var unshuffledQueue: [Track] = []
    private var resolveGeneration = 0
    /// Generation for which onTrackStarted has already fired, so a "play" is
    /// counted once and only after the item is actually ready (not on load,
    /// where it would also count tracks that then fail to resolve/play).
    private var notedPlayGeneration = -1
    private var audioSessionConfigured = false
    private var interruptedWhilePlaying = false
    /// Set by `restore(...)`: the queue + position were loaded from a previous
    /// session but NO player item has been resolved yet (so launch does no
    /// network I/O and the user lands paused). The first resume/seek lazily
    /// resolves and seeks to `elapsed`. Cleared the moment an item is loaded.
    private var needsInitialLoad = false

    /// Fires on the periodic time observer (~every 0.5s) so an owner can persist
    /// the current position. Throttle on the receiving side.
    var onPlaybackTick: (@MainActor () -> Void)?
    /// When a fresh item should resume mid-track (stall recovery), the seconds to
    /// seek to once it reaches `.readyToPlay`. Cleared after it is applied.
    private var resumeSeekTarget: Double = 0
    /// A seek is in flight. While set, the periodic observer is suppressed so the
    /// displayed time can't run ahead of audio, and rapid scrubs coalesce into
    /// `pendingSeekSeconds` (only the latest target is honoured).
    private var isSeeking = false
    private var pendingSeekSeconds: Double?
    /// After a seek lands, playback is held (the player keeps filling its buffer
    /// while paused) until ~`prerollSeconds` is actually buffered ahead, then it
    /// resumes — so rapid scrubs don't resume on AVPlayer's thin "minimize
    /// stalling" buffer (<2s). Cancelled by a new seek / pause / item change.
    private var prerollTask: Task<Void, Never>?
    private var isPrerolling = false
    /// Seconds of audio to buffer ahead before resuming after a seek.
    private static let prerollSeconds: Double = 5
    /// Cap the pre-roll wait so a slow/dead stream still resumes (the stall
    /// watchdog then covers a genuine wedge) instead of spinning forever.
    private static let prerollMaxWaitNanos: UInt64 = 8_000_000_000
    private static let prerollPollNanos: UInt64 = 150_000_000
    /// Fires when the player sits in the buffering state too long without progress
    /// and auto-rebuilds the item. Cancelled/replaced on every state change.
    private var stallWatchdogTask: Task<Void, Never>?
    /// Consecutive automatic stall recoveries for the current item; reset once it
    /// actually plays. Bounds runaway re-resolve loops on a truly dead source.
    private var recoveryAttempts = 0
    /// How long the player may sit buffering (with no progress) before we rebuild
    /// the current item on a fresh connection. Longer than the SMB read timeout +
    /// reconnect (~12s) so the lower layer gets first chance to self-heal.
    private static let stallRecoveryDelayNanos: UInt64 = 20_000_000_000
    private static let maxStallRecoveries = 3

    init() {
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        addPeriodicTimeObserver()
        observeTimeControlStatus()
        configureRemoteCommands()
        observeInterruptions()
    }

    // Note: no explicit `deinit` to remove the periodic time observer — AVPlayer
    // releases it on dealloc, and a nonisolated deinit touching the MainActor
    // player would violate Swift 6 isolation. The observer captures self weakly.

    // MARK: Queue control

    /// Replace the queue and start playing at `startIndex`.
    func play(_ tracks: [Track], startAt startIndex: Int = 0) {
        guard !tracks.isEmpty else { return }
        unshuffledQueue = tracks
        if shuffleEnabled {
            queue = shuffledQueue(tracks, keeping: startIndex)
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = min(max(startIndex, 0), tracks.count - 1)
        }
        startCurrentItem(autoPlay: true)
    }

    /// Restore a previous session's queue + position WITHOUT auto-playing or
    /// touching the network. The user lands paused on `queue[index]` at `elapsed`;
    /// the first resume/seek resolves the item and seeks there. `queue` is the
    /// live (already-shuffled, if applicable) order.
    func restore(queue: [Track], index: Int, elapsed: Double, shuffle: Bool, repeatMode: RepeatMode) {
        guard !queue.isEmpty, queue.indices.contains(index) else { return }
        cancelStallWatchdog()
        cancelPreroll()
        resolveGeneration += 1
        self.queue = queue
        self.unshuffledQueue = queue
        self.currentIndex = index
        self.shuffleEnabled = shuffle
        self.repeatMode = repeatMode
        self.elapsed = max(0, elapsed)
        self.duration = queue[index].durationSeconds
        self.isPlaying = false
        self.isBuffering = false
        self.lastErrorMessage = nil
        self.needsInitialLoad = true
        self.currentArtwork = nil
        let track = queue[index]
        let generation = resolveGeneration
        if let loadArtwork {
            Task { [weak self] in
                let image = await loadArtwork(track)
                guard let self, self.needsInitialLoad, generation == self.resolveGeneration else { return }
                self.currentArtwork = image
                self.updateNowPlayingInfo()
            }
        }
        updateNowPlayingInfo()
    }

    /// Shuffle a fresh set and start from a random track (not pinned to index 0).
    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffleEnabled = true
        unshuffledQueue = tracks
        queue = tracks.shuffled()
        currentIndex = 0
        startCurrentItem(autoPlay: true)
    }

    func playNext(_ track: Track) {
        let insertAt = min(currentIndex + 1, queue.count)
        queue.insert(track, at: insertAt)
        unshuffledQueue.append(track)
        if queue.count == 1 { startCurrentItem(autoPlay: true) }
    }

    func addToQueue(_ track: Track) {
        queue.append(track)
        unshuffledQueue.append(track)
        if queue.count == 1 { startCurrentItem(autoPlay: true) }
    }

    func removeFromQueue(at offsets: IndexSet) {
        // Never remove the currently playing item via list edit.
        let safe = offsets.filter { $0 != currentIndex && queue.indices.contains($0) }
        guard !safe.isEmpty else { return }
        let removedBeforeCurrent = safe.filter { $0 < currentIndex }.count
        let removedIDs = Set(safe.map { queue[$0].id })
        for index in safe.sorted(by: >) { queue.remove(at: index) }
        currentIndex -= removedBeforeCurrent
        // Keep the shuffle-source in sync, else toggling shuffle off resurrects
        // the removed tracks.
        unshuffledQueue.removeAll { removedIDs.contains($0.id) }
    }

    func moveQueueItem(fromOffsets source: IndexSet, toOffset destination: Int) {
        let current = currentTrack
        queue.move(fromOffsets: source, toOffset: destination)
        // Match by id: full-struct equality breaks if a field (isFavorite/
        // cacheState) diverged between `current` and the queue copy.
        if let current, let newIndex = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = newIndex
        }
    }

    func clearQueue() {
        queue = []
        unshuffledQueue = []
        currentIndex = 0
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        elapsed = 0
        duration = 0
        updateNowPlayingInfo()
    }

    // MARK: Transport

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard currentTrack != nil else { return }
        if needsInitialLoad {
            // Restored session: resolve the item now and resume at the saved point.
            startCurrentItem(autoPlay: true, resumeAt: elapsed)
            return
        }
        configureAudioSessionIfNeeded()
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
        cancelStallWatchdog()
        cancelPreroll()   // don't auto-resume from a pending pre-roll after a manual pause
        updateNowPlayingInfo()
    }

    func next() {
        advance(userInitiated: true)
    }

    func previous() {
        if elapsed > 3 {
            seek(toFraction: 0)
            return
        }
        guard currentIndex > 0 else {
            seek(toFraction: 0)
            return
        }
        currentIndex -= 1
        startCurrentItem(autoPlay: isPlaying)
    }

    func seek(toFraction fraction: Double) {
        guard duration > 0 else { return }
        seek(toSeconds: fraction * duration)
    }

    func seek(toSeconds seconds: Double) {
        // Don't clamp to 0 when duration isn't known yet (e.g. a restored track
        // whose asset duration hasn't resolved at resume-seek time) — that would
        // snap the resume position to 0:00. AVPlayer clamps to the real end itself.
        let clamped = duration > 0 ? min(max(seconds, 0), duration) : max(seconds, 0)
        if needsInitialLoad {
            // Restored-but-unloaded: load (paused) at the scrubbed point.
            startCurrentItem(autoPlay: false, resumeAt: clamped)
            return
        }
        // Reflect the target immediately so the scrubber tracks the finger, and
        // freeze the timer there: the periodic observer is suppressed while
        // seeking, so the displayed time can't advance silently before audio
        // actually resumes at the new point.
        elapsed = clamped
        updateNowPlayingInfo()
        if isSeeking {
            pendingSeekSeconds = clamped   // coalesce rapid scrubs to the latest
            return
        }
        performSeek(to: clamped)
    }

    private func performSeek(to seconds: Double) {
        isSeeking = true
        cancelPreroll()   // a fresh seek supersedes any in-progress pre-roll
        // Scrubbing to an un-cached position must fetch from the source; show
        // activity immediately instead of a frozen or "playing-but-silent" UI.
        if isPlaying { isBuffering = true }
        let generation = resolveGeneration
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // A small tolerance lets AVPlayer land on a nearby fetchable point instead
        // of forcing the exact byte (`.zero`), which over the streaming loader made
        // scrubs slow and produced the play-1s → jump → silent-rebuffer stutter.
        let tolerance = CMTime(seconds: 1.0, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The track changed mid-seek: abandon this stale completion so it
                // can't seek the new item (the new item resets seek state itself).
                guard generation == self.resolveGeneration else { return }
                if let next = self.pendingSeekSeconds {
                    self.pendingSeekSeconds = nil
                    self.performSeek(to: next)   // honour the latest scrub target
                    return
                }
                self.isSeeking = false
                if finished {
                    let now = self.player.currentTime().seconds
                    self.elapsed = now.isFinite ? now : seconds
                }
                if self.isPlaying {
                    // Hold playback until there's a real buffer cushion, so rapid
                    // scrubs don't resume on AVPlayer's thin (<2s) buffer.
                    self.beginPreroll(generation: generation)
                } else {
                    self.isBuffering = (self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                }
                self.updateNowPlayingInfo()
            }
        }
    }

    /// Hold playback after a seek until ~`prerollSeconds` is buffered ahead (or the
    /// item is fully buffered / near the end / the wait cap elapses), then resume.
    /// AVPlayer keeps filling `loadedTimeRanges` toward `preferredForwardBufferDuration`
    /// even while paused, so this just defers `play()` until there's a real cushion.
    private func beginPreroll(generation: Int) {
        prerollTask?.cancel()
        // Already enough buffered (e.g. scrubbing within the loaded region): resume now.
        if bufferedAheadSeconds >= Self.prerollSeconds {
            isPrerolling = false
            isBuffering = false
            player.play()
            return
        }
        isPrerolling = true
        isBuffering = true
        player.pause()   // hold; AVPlayer still prefetches into its buffer while paused
        prerollTask = Task { [weak self] in
            var waited: UInt64 = 0
            while waited < Self.prerollMaxWaitNanos {
                try? await Task.sleep(nanoseconds: Self.prerollPollNanos)
                waited += Self.prerollPollNanos
                guard !Task.isCancelled, let self else { return }
                guard generation == self.resolveGeneration, self.isPrerolling else { return }
                let ahead = self.bufferedAheadSeconds
                let full = self.player.currentItem?.isPlaybackBufferFull ?? false
                let nearEnd = self.duration > 0 && self.elapsed + Self.prerollSeconds >= self.duration
                if ahead >= Self.prerollSeconds || full || nearEnd { break }
            }
            guard !Task.isCancelled, let self else { return }
            guard generation == self.resolveGeneration, self.isPrerolling, self.isPlaying else { return }
            self.isPrerolling = false
            self.prerollTask = nil
            self.player.play()
            self.isBuffering = (self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        }
    }

    private func cancelPreroll() {
        prerollTask?.cancel()
        prerollTask = nil
        isPrerolling = false
    }

    func toggleShuffle() {
        setShuffle(!shuffleEnabled)
    }

    func setShuffle(_ enabled: Bool) {
        guard enabled != shuffleEnabled else { return }
        shuffleEnabled = enabled
        let current = currentTrack
        if enabled {
            if unshuffledQueue.isEmpty { unshuffledQueue = queue }
            queue = shuffledQueue(queue, keeping: currentIndex)
            currentIndex = 0
        } else {
            queue = unshuffledQueue
            if let current, let idx = queue.firstIndex(where: { $0.id == current.id }) {
                currentIndex = idx
            }
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func toggleFavoriteOnCurrent() {
        guard queue.indices.contains(currentIndex) else { return }
        queue[currentIndex].isFavorite.toggle()
    }

    // MARK: Item lifecycle

    private func startCurrentItem(autoPlay: Bool, resumeAt: Double = 0) {
        guard let track = currentTrack else { return }
        #if DEBUG
        print("BETTERSTREAMING_PLAY start title=\(track.title) ext=\(track.fileExtension) source=\(track.sourceID) remote=\(track.remotePath ?? "nil") resumeAt=\(resumeAt)")
        #endif
        cancelStallWatchdog()
        cancelPreroll()
        needsInitialLoad = false   // we're resolving an item now
        isSeeking = false
        pendingSeekSeconds = nil
        resolveGeneration += 1
        let generation = resolveGeneration
        isBuffering = true
        elapsed = resumeAt
        resumeSeekTarget = resumeAt
        duration = track.durationSeconds
        lastErrorMessage = nil

        // Load artwork in parallel with asset resolution.
        currentArtwork = nil
        if let loadArtwork {
            Task { [weak self] in
                let image = await loadArtwork(track)
                guard let self, generation == self.resolveGeneration else { return }
                self.currentArtwork = image
                self.updateNowPlayingInfo()
            }
        }

        Task { [weak self] in
            guard let self else { return }
            let item: AVPlayerItem?
            if let resolvePlayerItem = self.resolvePlayerItem {
                item = await resolvePlayerItem(track)
            } else if let resolveAsset = self.resolveAsset, let url = await resolveAsset(track) {
                item = AVPlayerItem(url: url)
            } else if let url = track.assetURL {
                item = AVPlayerItem(url: url)
            } else {
                item = nil
            }
            guard generation == self.resolveGeneration else { return }
            guard let item else {
                self.isBuffering = false
                self.lastErrorMessage = "“\(track.title)” isn’t available offline."
                #if DEBUG
                print("BETTERSTREAMING_PLAY resolve_nil title=\(track.title) ext=\(track.fileExtension)")
                #endif
                self.stopAfterFailure()
                return
            }
            #if DEBUG
            print("BETTERSTREAMING_PLAY resolved title=\(track.title) ext=\(track.fileExtension)")
            #endif
            self.loadPlayerItem(item: item, autoPlay: autoPlay, generation: generation)
        }
    }

    /// Seconds of audio AVPlayer should keep buffered ahead of the playhead. A
    /// scrub into an un-cached region otherwise plays the tiny default buffer,
    /// starves, and lets the clock run past the audio (→ "plays a moment, lags,
    /// then resumes skipping the gap"). ≈0.5 MB for MP3, ~1–2 MB for FLAC at 10s.
    private static let preferredForwardBufferSeconds: TimeInterval = 10

    private func loadPlayerItem(item: AVPlayerItem, autoPlay: Bool, generation: Int) {
        // AVPlayerItem.duration is often `.indefinite` until well after
        // readyToPlay for these files, which left the scrubber/timer at 0:00.
        // Load it directly from the asset, which is reliable.
        let durationAsset = item.asset
        Task { @MainActor in
            guard generation == self.resolveGeneration else { return }
            if let cmDuration = try? await durationAsset.load(.duration) {
                let seconds = cmDuration.seconds
                if seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                    self.updateNowPlayingInfo()
                    if self.queue.indices.contains(self.currentIndex) {
                        self.onDurationResolved?(self.queue[self.currentIndex].id, seconds)
                    }
                }
            }
        }

        statusObservation?.invalidate()
        // Read only Sendable values out of the KVO callback (status enum); never
        // capture the non-Sendable AVPlayerItem into the MainActor task.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] _, change in
            let status = change.newValue ?? .unknown
            Task { @MainActor in
                guard let self, generation == self.resolveGeneration else { return }
                switch status {
                case .readyToPlay:
                    self.isBuffering = false
                    if let assetDuration = self.player.currentItem?.duration.seconds,
                       assetDuration.isFinite, assetDuration > 0 {
                        self.duration = assetDuration
                    }
                    // Stall-recovery / resume: jump back to where playback was.
                    if self.resumeSeekTarget > 1 {
                        let target = self.resumeSeekTarget
                        self.resumeSeekTarget = 0
                        self.seek(toSeconds: target)
                    }
                    #if DEBUG
                    let duration = self.duration.isFinite ? self.duration : -1
                    print("BETTERSTREAMING_PLAY ready index=\(self.currentIndex) duration=\(duration)")
                    #endif
                    // Count the play only once the item is genuinely ready.
                    if self.notedPlayGeneration != generation,
                       self.queue.indices.contains(self.currentIndex) {
                        self.notedPlayGeneration = generation
                        self.onTrackStarted?(self.queue[self.currentIndex])
                    }
                    self.updateNowPlayingInfo()
                case .failed:
                    self.isBuffering = false
                    self.lastErrorMessage = self.player.currentItem?.error?.localizedDescription ?? "Playback failed."
                    let itemError = self.player.currentItem?.error?.localizedDescription ?? "nil"
                    let errLog = self.player.currentItem?.errorLog()?.events.last
                    streamLog.error("item_failed err=\(itemError, privacy: .public) log=\(errLog?.errorStatusCode ?? 0):\(errLog?.errorComment ?? "nil", privacy: .public)")
                    self.stopAfterFailure()
                default:
                    break
                }
            }
        }

        if let itemEndObserver { NotificationCenter.default.removeObserver(itemEndObserver) }
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded()
            }
        }

        item.preferredForwardBufferDuration = Self.preferredForwardBufferSeconds
        player.replaceCurrentItem(with: item)
        if autoPlay {
            configureAudioSessionIfNeeded()
            player.play()
            isPlaying = true
            #if DEBUG
            let route = AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            print("BETTERSTREAMING_PLAY player_play route=\(route) volume=\(AVAudioSession.sharedInstance().outputVolume)")
            #endif
        }
        // onTrackStarted is fired from the .readyToPlay observation, not here,
        // so a track that fails to resolve/play is never counted as a play.
        updateNowPlayingInfo()
    }

    /// When set (sleep timer "end of track"), playback pauses at the end of the
    /// current track instead of advancing.
    var stopAtTrackEnd = false

    private func handlePlaybackEnded() {
        if stopAtTrackEnd {
            stopAtTrackEnd = false
            pause()
            return
        }
        if repeatMode == .one {
            seek(toSeconds: 0)
            player.play()
            return
        }
        let playerTime = player.currentTime().seconds
        let playedSeconds = max(elapsed, playerTime.isFinite ? playerTime : 0)
        let itemDuration = player.currentItem?.duration.seconds ?? 0
        let knownDuration = max(duration, itemDuration.isFinite ? itemDuration : 0)
        if playedSeconds < 0.75 && knownDuration < 0.75 {
            lastErrorMessage = "Playback ended before audio started."
            stopAfterFailure()
            return
        }
        advance(userInitiated: false)
    }

    private func advance(userInitiated: Bool) {
        if currentIndex < queue.count - 1 {
            currentIndex += 1
            startCurrentItem(autoPlay: true)
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
            startCurrentItem(autoPlay: true)
        } else {
            // Reached the end of the queue.
            isPlaying = false
            player.pause()
            seek(toSeconds: 0)
        }
    }

    /// Keep the failed selection visible instead of racing through the queue.
    private func stopAfterFailure() {
        player.pause()
        isPlaying = false
        isBuffering = false
        #if DEBUG
        print("BETTERSTREAMING_PLAY stop_after_failure message=\(lastErrorMessage ?? "nil")")
        #endif
        updateNowPlayingInfo()
    }

    private func shuffledQueue(_ tracks: [Track], keeping index: Int) -> [Track] {
        guard tracks.indices.contains(index) else { return tracks.shuffled() }
        let head = tracks[index]
        var rest = tracks
        rest.remove(at: index)
        return [head] + rest.shuffled()
    }

    // MARK: Time observation

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only advance the displayed time when audio is genuinely rolling:
                // not mid-seek, and the player is actually playing (not waiting or
                // buffering). This stops the timer from running ahead of sound and
                // then "skipping" once the buffer at the new point finally fills.
                guard !self.isSeeking, self.player.timeControlStatus == .playing else { return }
                if seconds.isFinite { self.elapsed = seconds }
                self.onPlaybackTick?()
            }
        }
    }

    private func observeTimeControlStatus() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
            Task { @MainActor in
                guard let self else { return }
                // Buffering = waiting to play (initial fill or a mid-track stall),
                // or holding for the post-seek pre-roll. Show activity, not a freeze.
                self.isBuffering = (status == .waitingToPlayAtSpecifiedRate) || self.isPrerolling
                switch status {
                case .playing:
                    self.recoveryAttempts = 0
                    self.cancelStallWatchdog()
                case .waitingToPlayAtSpecifiedRate:
                    self.scheduleStallWatchdog()
                case .paused:
                    self.cancelStallWatchdog()
                @unknown default:
                    break
                }
                streamLog.info("timeControl=\(status.rawValue) reason=\(reason, privacy: .public) elapsed=\(self.elapsed)")
            }
        }
    }

    // MARK: Stall recovery

    /// If the player sits in the buffering (`waitingToPlayAtSpecifiedRate`) state
    /// for too long without making progress — while the user intends to play —
    /// rebuild the current item from scratch (fresh resolve → fresh SMB
    /// connection) and resume at the saved position. This is the automatic
    /// equivalent of "skip to the next track and back", which the user found
    /// temporarily un-stuck playback. The lower SMB layer self-heals a wedged
    /// connection on its own read timeout; this is the catch-all for any stall it
    /// can't reach (e.g. a wedge during the initial buffer fill, or an
    /// AVPlayer-internal stall).
    private func scheduleStallWatchdog() {
        guard isPlaying else { return }          // a paused player isn't "stalled"
        guard stallWatchdogTask == nil else { return }
        let generation = resolveGeneration
        let startElapsed = elapsed
        let startBuffered = bufferedAheadSeconds
        stallWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.stallRecoveryDelayNanos)
            guard !Task.isCancelled, let self else { return }
            self.stallWatchdogTask = nil
            guard generation == self.resolveGeneration else { return }   // item changed
            guard self.isPlaying,
                  self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            // Real progress while waiting means it isn't wedged — leave it alone.
            if self.elapsed > startElapsed + 0.5 || self.bufferedAheadSeconds > startBuffered + 0.5 {
                return
            }
            guard self.recoveryAttempts < Self.maxStallRecoveries else {
                streamLog.error("stall_watchdog give_up attempts=\(self.recoveryAttempts) at=\(self.elapsed)")
                self.lastErrorMessage = "Playback stalled. Check the connection to your library."
                return
            }
            self.recoveryAttempts += 1
            streamLog.error("stall_watchdog recover attempt=\(self.recoveryAttempts) at=\(self.elapsed)")
            self.recoverCurrentItem()
        }
    }

    private func cancelStallWatchdog() {
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
    }

    /// Re-resolve and reload the current track, resuming at the current position.
    private func recoverCurrentItem() {
        guard currentTrack != nil else { return }
        startCurrentItem(autoPlay: true, resumeAt: elapsed)
    }

    /// Seconds of audio buffered ahead of the playhead (from the player's loaded
    /// ranges), so the UI can show "buffering N s" progress while waiting.
    var bufferedAheadSeconds: Double {
        guard let item = player.currentItem else { return 0 }
        let now = item.currentTime().seconds
        guard now.isFinite else { return 0 }
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            if start.isFinite, end.isFinite, now >= start - 0.5, now <= end {
                return max(0, end - now)
            }
        }
        return 0
    }

    // MARK: Audio session

    private func configureAudioSessionIfNeeded() {
        guard !audioSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            audioSessionConfigured = true
        } catch {
            lastErrorMessage = "Audio session error: \(error.localizedDescription)"
        }
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard
            let typeValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            interruptedWhilePlaying = isPlaying
            pause()
        case .ended:
            let options = optionsValue.map(AVAudioSession.InterruptionOptions.init)
            if interruptedWhilePlaying, options?.contains(.shouldResume) == true {
                // iOS deactivates our session during the interruption; the
                // one-shot `configureAudioSessionIfNeeded` won't re-activate it, so
                // `resume()`'s `play()` would silently no-op. Reactivate first.
                try? AVAudioSession.sharedInstance().setActive(true)
                resume()
            }
            interruptedWhilePlaying = false
        @unknown default:
            break
        }
    }

    // MARK: Now Playing + remote commands

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let safeDuration = duration.isFinite && duration >= 0 ? duration : 0
        let safeElapsed = elapsed.isFinite && elapsed >= 0 ? elapsed : 0
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: safeDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safeElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let art = currentArtwork {
            info[MPMediaItemPropertyArtwork] = Self.nowPlayingArtwork(from: art)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    nonisolated private static func nowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // Remote command handlers are delivered on the main thread, so it's safe
        // to bridge into the MainActor synchronously.
        // Remote commands may be delivered off the main thread on some OS
        // versions; hop to the main actor explicitly rather than asserting it.
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(toSeconds: position) }
            return .success
        }
    }
}
