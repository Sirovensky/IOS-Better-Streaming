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
    /// Codec / bit-depth / sample-rate of the playing item, read from the decoded
    /// asset (e.g. "FLAC · 24-bit · 96 kHz"). Falls back to the file-extension
    /// label until the asset resolves; nil before anything plays.
    private(set) var currentFormatDetail: String?

    var currentTrack: Track? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

#if DEBUG
    /// Seeds a mock now-playing track WITHOUT real playback, so the player UI can
    /// be rendered in the Simulator for visual iteration (no SMB needed). Triggered
    /// by the `-uiPreview` launch argument; never reached in a release build.
    func debugSeedNowPlaying(_ track: Track, elapsed: Double, restorable: Bool = false) {
        queue = [track]
        unshuffledQueue = [track]
        currentIndex = 0
        duration = track.durationSeconds
        self.elapsed = elapsed
        isPlaying = false
        isBuffering = false
        // `restorable` mimics a restored-but-not-resumed session so the Home
        // "Continue where you left off" hero (gated on hasRestorableSession) shows.
        needsInitialLoad = restorable
        // Mock the asset-resolved format detail so the player's format chip can be
        // screenshotted (no real AVAsset to read in the sim).
        currentFormatDetail = "FLAC · 24-bit · 96 kHz"
    }
#endif

    var hasNext: Bool {
        // repeat-one doesn't advance, so it shouldn't enable Next at the last
        // track (where advance() just stops); only repeat-all wraps.
        currentIndex < queue.count - 1 || repeatMode == .all
    }

    var hasPrevious: Bool {
        currentIndex > 0 || elapsed > 3
    }

    /// Track ids whose cached file must not be evicted: the currently-playing item and
    /// any gapless-preloaded next item. Deleting their backing file mid-session breaks
    /// the live item or the seamless advance. The auto-cache executor honours this.
    var protectedTrackIDs: Set<String> {
        var ids = Set<String>()
        if let current = currentTrack { ids.insert(current.id) }
        if let idx = preloadedNextIndex, queue.indices.contains(idx) { ids.insert(queue[idx].id) }
        return ids
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
    /// Called when the crossfade setting changes, with whether a crossfade is now
    /// active. The owner wires it to the streaming service's `preferPreciseDuration`
    /// so streamed items load precise duration/timing while crossfade needs an
    /// accurate track end. Called from init + the enhancement hooks below.
    var onCrossfadeActiveChanged: (@MainActor (Bool) -> Void)?

    // MARK: Private

    // AVQueuePlayer (an AVPlayer subclass) so a preloaded next item can transition
    // sample-accurately (gapless). With a single queued item it behaves exactly
    // like AVPlayer; the gapless lookahead is added on top.
    private let player = AVQueuePlayer()
    /// Opt-in audio tweaks (ReplayGain / preamp / EQ). All default off.
    let enhancements = AudioEnhancements()
    private var timeObserver: Any?
    private var itemEndObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    /// The item WE made current (via load/skip). Lets the end-of-track handler
    /// tell a gapless auto-advance (currentItem already moved to our preload) from
    /// a normal end.
    private var currentPlayerItem: AVPlayerItem?
    /// The lookahead item enqueued after the current one for gapless transition,
    /// and the queue index it represents. Cleared on any queue mutation.
    private var preloadedNextItem: AVPlayerItem?
    private var preloadedNextIndex: Int?
    /// The pre-shuffle play order, so shuffle-off restores it. Readable so a
    /// session snapshot can persist it and restore true un-shuffle after relaunch.
    private(set) var unshuffledQueue: [Track] = []
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
    private(set) var needsInitialLoad = false

    /// True when a previous session was restored (queue + position) but has NOT been
    /// resumed yet. This is the one state where the Home "Continue where you left off"
    /// hero is shown; its tap calls `resume()`, which seeks to the saved `elapsed`.
    var hasRestorableSession: Bool { needsInitialLoad && currentTrack != nil }

    /// Fires on the periodic time observer (~every 0.1s) so an owner can persist
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
    /// Consecutive auto-skips past a track that failed to load after a non-user
    /// advance. Bounds an unattended session against one dead file mid-queue: skip
    /// forward up to `maxConsecutiveFailureSkips`, then stop as before. Reset once a
    /// track actually reaches `.readyToPlay`.
    private var consecutiveFailureSkips = 0
    private static let maxConsecutiveFailureSkips = 2
    /// True while the CURRENT load was reached via a non-user auto-advance, so a
    /// failure can decide whether it's allowed to skip forward rather than halt.
    private var currentLoadWasAutoAdvance = false
    /// Keep the failed track's error message visible across the skip's next load
    /// (`startCurrentItem` otherwise clears it as the new item begins resolving).
    private var preserveErrorOnNextLoad = false
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
        observeRouteChanges()
        observeMediaServicesReset()
        syncCrossfadeActive()
    }

    /// Whether a crossfade is currently configured (matches the 0.1 s threshold
    /// used across the fade logic). Streamed items prefer precise duration/timing
    /// while this is true so the end-of-track fade lands accurately.
    private func syncCrossfadeActive() {
        onCrossfadeActiveChanged?(enhancements.crossfadeSeconds > 0.1)
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
    func restore(queue: [Track], index: Int, elapsed: Double, shuffle: Bool, repeatMode: RepeatMode, unshuffled: [Track]? = nil) {
        guard !queue.isEmpty, queue.indices.contains(index) else { return }
        cancelStallWatchdog()
        cancelPreroll()
        resolveGeneration += 1
        self.queue = queue
        // A snapshot that persisted the pre-shuffle order restores it so shuffle-off
        // yields the real order; otherwise fall back to the live (possibly shuffled) queue.
        self.unshuffledQueue = unshuffled ?? queue
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
        clearArtworkCache()
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
        // Insert right after the current track in the shuffle-source too (match by
        // id), so "play next" survives a later shuffle-off instead of jumping to the
        // end.
        if let current = currentTrack,
           let idx = unshuffledQueue.firstIndex(where: { $0.id == current.id }) {
            unshuffledQueue.insert(track, at: min(idx + 1, unshuffledQueue.count))
        } else {
            unshuffledQueue.append(track)
        }
        clearPreload()   // the immediate-next track changed
        if queue.count == 1 { startCurrentItem(autoPlay: true) }
        else { preloadNextIfGapless() }
    }

    func addToQueue(_ track: Track) {
        queue.append(track)
        unshuffledQueue.append(track)
        if queue.count == 1 { startCurrentItem(autoPlay: true) }
        else { clearPreload(); preloadNextIfGapless() }
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
        clearPreload(); preloadNextIfGapless()   // next may have changed
    }

    func moveQueueItem(fromOffsets source: IndexSet, toOffset destination: Int) {
        let current = currentTrack
        queue.move(fromOffsets: source, toOffset: destination)
        // Match by id: full-struct equality breaks if a field (isFavorite/
        // cacheState) diverged between `current` and the queue copy.
        if let current, let newIndex = queue.firstIndex(where: { $0.id == current.id }) {
            currentIndex = newIndex
        }
        // Keep the shuffle-source in sync when not shuffled, so a manual reorder isn't
        // discarded when shuffle is later toggled off (which restores unshuffledQueue).
        if !shuffleEnabled { unshuffledQueue = queue }
        clearPreload(); preloadNextIfGapless()   // next may have changed
    }

    func clearQueue() {
        queue = []
        unshuffledQueue = []
        currentIndex = 0
        clearPreload()
        player.removeAllItems()
        currentPlayerItem = nil
        isPlaying = false
        elapsed = 0
        duration = 0
        updateNowPlayingInfo()
    }

    /// Push refreshed `Track` value-copies into the live queue (after a metadata
    /// edit or a cacheState change on the owner's side). Matches by id and preserves
    /// order, `currentIndex`, and which item is current — only the value contents
    /// change. Refreshes the lock screen when the current track's data changed, and
    /// re-stages the gapless preload when the NEXT track's cacheState changed (the
    /// copy `preloadNextIfGapless` reads was stale, so a just-cached next now
    /// becomes preloadable).
    func updateQueueTracks(_ updated: [Track]) {
        guard !updated.isEmpty else { return }
        let byID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let currentID = currentTrack?.id
        let nextIndex = gaplessNextIndex
        let oldNextCacheState = nextIndex.flatMap { queue.indices.contains($0) ? queue[$0].cacheState : nil }

        var currentChanged = false
        for i in queue.indices {
            guard let fresh = byID[queue[i].id] else { continue }
            if queue[i].id == currentID { currentChanged = true }
            queue[i] = fresh
        }
        for i in unshuffledQueue.indices {
            if let fresh = byID[unshuffledQueue[i].id] { unshuffledQueue[i] = fresh }
        }

        if currentChanged { updateNowPlayingInfo() }
        if let nextIndex, queue.indices.contains(nextIndex),
           queue[nextIndex].cacheState != oldNextCacheState {
            clearPreload()
            preloadNextIfGapless()
        }
    }

    /// Swap re-keyed tracks into the live queue after a rescan identity remap:
    /// `mapping` is OLD id → the NEW `Track`. Unlike `updateQueueTracks` (which
    /// matches by unchanged id), the id itself changes here — without this, the
    /// periodic snapshot tick re-persists the dead old ids and clobbers the
    /// corrected snapshot, dropping the queue on next launch.
    func remapQueueTracks(_ mapping: [String: Track]) {
        guard !mapping.isEmpty else { return }
        var currentChanged = false
        for i in queue.indices {
            guard let fresh = mapping[queue[i].id] else { continue }
            if i == currentIndex { currentChanged = true }
            queue[i] = fresh
        }
        for i in unshuffledQueue.indices {
            if let fresh = mapping[unshuffledQueue[i].id] { unshuffledQueue[i] = fresh }
        }
        if currentChanged { updateNowPlayingInfo() }
    }

    /// Jump straight to a queue position and play it (queue UI tap-to-jump).
    func jump(toQueueIndex index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        startCurrentItem(autoPlay: true)
    }

    /// Drop everything after the current track ("Clear Playing Next"), keeping the
    /// current item playing. Removes the matching entries from the shuffle source
    /// too (so a later shuffle-off can't resurrect them) and invalidates the preload.
    func clearUpcoming() {
        guard queue.indices.contains(currentIndex), currentIndex < queue.count - 1 else { return }
        let removedIDs = Set(queue[(currentIndex + 1)...].map(\.id))
        queue.removeSubrange((currentIndex + 1)...)
        unshuffledQueue.removeAll { removedIDs.contains($0.id) && $0.id != currentTrack?.id }
        clearPreload()
        preloadNextIfGapless()
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
        // After a resolve/playback failure the current item was torn down (nil) or is
        // in a `.failed` state; a bare `play()` would resume the PREVIOUS track's audio
        // or silently no-op. Re-resolve the current track from scratch instead.
        if currentPlayerItem == nil || currentPlayerItem?.status == .failed {
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
            #if DEBUG
            AppLog.playback.debug("BETTERSTREAMING_SEEK coalesce pending=\(clamped) elapsed=\(self.elapsed) (in-flight)")
            #endif
            return
        }
        performSeek(to: clamped)
    }

    private func performSeek(to seconds: Double) {
        isSeeking = true
        #if DEBUG
        AppLog.playback.debug("BETTERSTREAMING_SEEK perform to=\(seconds) gen=\(self.resolveGeneration) elapsed=\(self.elapsed) dur=\(self.duration)")
        #endif
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
                #if DEBUG
                AppLog.playback.debug("BETTERSTREAMING_SEEK done to=\(seconds) finished=\(finished) gen=\(generation) curGen=\(self.resolveGeneration) pending=\(self.pendingSeekSeconds ?? -1) playerTime=\(self.player.currentTime().seconds) ctrl=\(self.player.timeControlStatus.rawValue)")
                #endif
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
        clearPreload(); preloadNextIfGapless()   // play order changed
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        // The preloaded "next" depends on repeat mode (esp. repeat-one / wrap).
        clearPreload()
        preloadNextIfGapless()
    }

    // MARK: Gapless lookahead

    /// React to the gapless setting toggling. Drop any staged preload (so turning it
    /// OFF doesn't fire one more gapless advance) and re-evaluate (preloadNextIfGapless
    /// is a no-op when gapless is off, so this both stages and clears correctly).
    func gaplessSettingChanged() {
        clearPreload()
        preloadNextIfGapless()
        syncCrossfadeActive()
    }

    /// Remove the preloaded next item from the queue and forget it. Called on any
    /// change that invalidates "what plays next" (load/skip/reorder/remove/shuffle).
    private func clearPreload() {
        if let preloadedNextItem { player.remove(preloadedNextItem) }
        preloadedNextItem = nil
        preloadedNextIndex = nil
    }

    private func fetchArtwork(for track: Track, generation: Int) {
        guard let loadArtwork else { return }
        Task { [weak self] in
            let image = await loadArtwork(track)
            guard let self, generation == self.resolveGeneration else { return }
            self.currentArtwork = image
            self.updateNowPlayingInfo()
        }
    }

    /// The index that follows the current one in play order (with repeat-all wrap).
    private var gaplessNextIndex: Int? {
        if currentIndex + 1 < queue.count { return currentIndex + 1 }
        if repeatMode == .all, !queue.isEmpty { return 0 }
        return nil
    }

    /// Preload the next track so it plays with no gap. Only when gapless is on,
    /// we're playing, not repeat-one, and the next track is already local/cached
    /// (so it adds NO streaming contention with the live track). Builds the item,
    /// sets its EQ + buffer, and enqueues it after the current item.
    private func preloadNextIfGapless() {
        // Crossfade and gapless are mutually exclusive on a single player: the
        // envelope fades the current track to 0 over the last cf seconds, then an
        // AVQueuePlayer hard-advance would start the preload at envelope 0 → a near-
        // silent gap. Let crossfade (the explicit overlap feature) win when both are
        // on; gapless resumes once crossfade is back to 0.
        guard enhancements.crossfadeSeconds <= 0.1 else { return }
        guard enhancements.gaplessEnabled, isPlaying, repeatMode != .one, !stopAtTrackEnd,
              let nextIndex = gaplessNextIndex, queue.indices.contains(nextIndex),
              let current = currentPlayerItem, player.currentItem === current else { return }
        let next = queue[nextIndex]
        guard next.kind == .audio else { return }
        // Only preload an already-on-device track (cached / prefetched / local).
        guard next.cacheState == .cached || next.cacheState == .prefetched else { return }
        // Already preloaded this index? Skip.
        if preloadedNextIndex == nextIndex, preloadedNextItem != nil { return }
        clearPreload()
        let generation = resolveGeneration
        Task { [weak self] in
            guard let self, let resolve = self.resolvePlayerItem else { return }
            guard let item = await resolve(next) else { return }
            // Bail if anything changed while resolving.
            guard generation == self.resolveGeneration,
                  self.enhancements.gaplessEnabled,
                  self.gaplessNextIndex == nextIndex,
                  let current = self.currentPlayerItem,
                  self.player.currentItem === current,
                  self.player.canInsert(item, after: current) else { return }
            item.preferredForwardBufferDuration = Self.preferredForwardBufferSeconds
            self.configureItemAudio(item)
            self.player.insert(item, after: current)
            self.preloadedNextItem = item
            self.preloadedNextIndex = nextIndex
        }
    }

    /// AVQueuePlayer transitioned gaplessly to our preloaded item — do the
    /// bookkeeping a normal load would (index, observers, started, volume, art),
    /// without replacing the item (which would interrupt the audio).
    private func gaplessAdvanced(to item: AVPlayerItem, index: Int) {
        cancelStallWatchdog()
        cancelPreroll()
        endSwitchFade()   // a gapless advance supersedes any in-flight switch-fade,
                          // else isSwitchFading stays set and mutes the rest of the queue
        preloadedNextItem = nil
        preloadedNextIndex = nil
        currentPlayerItem = item
        currentIndex = index
        resolveGeneration += 1
        let generation = resolveGeneration
        recoveryAttempts = 0
        consecutiveFailureSkips = 0
        isSeeking = false
        pendingSeekSeconds = nil
        resumeSeekTarget = 0
        isBuffering = false
        isPlaying = (player.timeControlStatus != .paused)
        elapsed = 0
        let track = currentTrack
        duration = track?.durationSeconds ?? 0
        lastErrorMessage = nil
        currentArtwork = nil
        clearArtworkCache()
        attachItemObservers(item, generation: generation)
        // The item is already playing (it was preloaded past readyToPlay), so the
        // status observer won't re-fire — count the play directly here.
        if let track {
            if notedPlayGeneration != generation {
                notedPlayGeneration = generation
                onTrackStarted?(track)
            }
            fetchArtwork(for: track, generation: generation)
        }
        applyReplayGainVolume(for: item, generation: generation)   // EQ mix was set at preload
        updateNowPlayingInfo()
        preloadNextIfGapless()
    }

    // MARK: Item lifecycle

    private func startCurrentItem(autoPlay: Bool, resumeAt: Double = 0, automaticAdvance: Bool = false) {
        guard let track = currentTrack else { return }
        currentLoadWasAutoAdvance = automaticAdvance
        // A user-initiated selection breaks any auto-skip chain.
        if !automaticAdvance { consecutiveFailureSkips = 0 }
        #if DEBUG
        AppLog.playback.debug("BETTERSTREAMING_PLAY start title=\(track.title) ext=\(track.fileExtension, privacy: .public) source=\(track.sourceID, privacy: .public) remote=\(track.remotePath ?? "nil") resumeAt=\(resumeAt)")
        #endif
        cancelStallWatchdog()
        cancelPreroll()
        fadeOutForSwitch()         // fade the old song while the new one loads
        needsInitialLoad = false   // we're resolving an item now
        isSeeking = false
        pendingSeekSeconds = nil
        resolveGeneration += 1
        let generation = resolveGeneration
        isBuffering = true
        elapsed = resumeAt
        resumeSeekTarget = resumeAt
        duration = track.durationSeconds
        // A failure-skip keeps the failed track's message on screen while the next
        // track loads; every other load clears it.
        if preserveErrorOnNextLoad {
            preserveErrorOnNextLoad = false
        } else {
            lastErrorMessage = nil
        }

        // Load artwork in parallel with asset resolution.
        currentArtwork = nil
        clearArtworkCache()
        fetchArtwork(for: track, generation: generation)

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
                self.endSwitchFade()   // no new item — don't strand the fade at silence
                self.isBuffering = false
                self.lastErrorMessage = "“\(track.title)” isn’t available offline."
                #if DEBUG
                AppLog.playback.debug("BETTERSTREAMING_PLAY resolve_nil title=\(track.title) ext=\(track.fileExtension, privacy: .public)")
                #endif
                self.handleLoadFailure()
                return
            }
            #if DEBUG
            AppLog.playback.debug("BETTERSTREAMING_PLAY resolved title=\(track.title) ext=\(track.fileExtension, privacy: .public)")
            #endif
            self.loadPlayerItem(item: item, autoPlay: autoPlay, generation: generation)
        }
    }

    /// Seconds of audio AVPlayer should keep buffered ahead of the playhead. A
    /// scrub into an un-cached region otherwise plays the tiny default buffer,
    /// starves, and lets the clock run past the audio (→ "plays a moment, lags,
    /// then resumes skipping the gap"). ≈0.5 MB for MP3, ~1–2 MB for FLAC at 10s.
    private static let preferredForwardBufferSeconds: TimeInterval = 10

    /// Apply opt-in audio enhancements to a freshly-built item. EQ (and its
    /// preamp) goes through an `MTAudioProcessingTap` audio mix; ReplayGain (and
    /// preamp when the EQ is off) is applied via `player.volume`, read from the
    /// asset's gain tags. Default-off → no audio mix, volume 1.0.
    /// Loudness base volume (ReplayGain / preamp), multiplied by the crossfade
    /// envelope to get the actual `player.volume`. 1.0 by default.
    private var baseVolume: Float = 1.0

    /// A short volume ramp on the OUTGOING item when switching to a track that
    /// still has to load (uncached/remote). Without it the old song plays on at
    /// full volume until the new item finishes buffering, which feels sluggish.
    /// `isSwitchFading` makes `applyVolume()` yield so the crossfade tick can't
    /// fight the ramp; the new item's load cancels the ramp and restores volume.
    private var switchFadeTask: Task<Void, Never>?
    private var isSwitchFading = false
    private static let switchFadeSeconds: Double = 1.0

    private func applyEnhancements(to item: AVPlayerItem, generation: Int) {
        configureItemAudio(item)                                   // per-item EQ
        applyReplayGainVolume(for: item, generation: generation)   // player-wide volume
    }

    /// Per-item EQ audio mix. Safe to set on a not-yet-current (preloaded) item.
    private func configureItemAudio(_ item: AVPlayerItem) {
        let e = enhancements
        // A flat EQ (all bands + preamp at 0) is audibly a no-op, so skip the
        // processing tap entirely — the tap adds a per-sample cost and a decode
        // path we don't want on for nothing.
        let hasEffect = e.eqEnabled && (e.eqBandsDB.contains { abs($0) > 0.01 } || abs(e.preampDB) > 0.01)
        item.audioMix = hasEffect
            ? AudioEQTap.makeAudioMix(bandsDB: e.eqBandsDB, preampDB: e.preampDB)
            : nil
    }

    /// ReplayGain/preamp via the player-wide `volume`. Only call for the CURRENT
    /// item (volume is global, so applying it for a preloaded item would wrongly
    /// change the track that's actually playing).
    private func applyReplayGainVolume(for item: AVPlayerItem, generation: Int) {
        let e = enhancements
        baseVolume = 1.0
        applyVolume()
        guard e.replayGainEnabled || (!e.eqEnabled && abs(e.preampDB) > 0.01) else { return }
        let assetToRead = item.asset
        Task { @MainActor in
            var db = 0.0
            if !e.eqEnabled { db += e.preampDB }   // preamp via volume only when EQ isn't carrying it
            if e.replayGainEnabled,
               let metadata = try? await assetToRead.load(.metadata),
               let rg = await AudioEnhancements.replayGainDB(from: metadata, preferAlbum: e.replayGainAlbumMode) {
                db += rg
            }
            guard generation == self.resolveGeneration else { return }
            self.baseVolume = min(1.0, AudioEnhancements.linear(fromDB: db))
            self.applyVolume()
        }
    }

    /// `player.volume = baseVolume × crossfade-envelope`. The envelope fades in
    /// over the first `crossfadeSeconds` and out over the last `crossfadeSeconds`
    /// of the track (0 = off → always 1). A single-player fade, not sample-gapless
    /// (true gapless would need AVQueuePlayer); contained and off by default.
    private func applyVolume() {
        // A switch-fade owns `player.volume` while it runs; don't let the crossfade
        // tick reset it back to full and undo the fade.
        guard !isSwitchFading else { return }
        let cf = enhancements.crossfadeSeconds
        var envelope: Float = 1
        if cf > 0.1, duration > cf * 2 {
            // Drive the envelope off the player's live time, not the 0.5 s display
            // tick, so the roll-off is smooth instead of 5-6 audible steps. With an
            // accurate duration (precise-timing asset) the fade reaches 0 exactly
            // at the real end — no early fade, no screamer, no silent tail.
            let t = player.currentTime().seconds
            let pos = t.isFinite ? t : elapsed
            let inGain = min(pos / cf, 1)
            let outGain = min((duration - pos) / cf, 1)
            envelope = Float(max(0, min(inGain, outGain)))
        }
        player.volume = baseVolume * envelope
    }

    /// Ramp the currently-playing item's volume to silence over `switchFadeSeconds`
    /// so a switch to a track that has to buffer doesn't keep blaring the old song
    /// until the new one loads. No-op when nothing is audibly playing (first track,
    /// paused, already silent). The new item's `loadPlayerItem` ends the fade and
    /// restores volume, so a fast (cached) load barely dips.
    private func fadeOutForSwitch() {
        switchFadeTask?.cancel()
        guard isPlaying, player.currentItem != nil else { return }
        let start = player.volume
        guard start > 0.01 else { return }
        isSwitchFading = true
        switchFadeTask = Task { @MainActor [weak self] in
            let steps = 24
            let stepNanos = UInt64(Self.switchFadeSeconds / Double(steps) * 1_000_000_000)
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: stepNanos)
                guard let self, !Task.isCancelled else { return }
                self.player.volume = start * Float(1 - Double(i) / Double(steps))
            }
        }
    }

    /// End any in-flight switch-fade and hand `player.volume` back to `applyVolume`.
    private func endSwitchFade() {
        switchFadeTask?.cancel()
        switchFadeTask = nil
        isSwitchFading = false
    }

    /// Build the player's format chip from a decoded asset's audio format:
    /// "FLAC · 24-bit · 96 kHz" for lossless (bit depth + rate are the quality),
    /// "MP3 · 320 kbps" for lossy (bitrate is the true quality; the sample rate
    /// is ~always 44.1/48 and tells the listener nothing). Classified by the
    /// decoder's mFormatID, not the file extension (an .m4a can be AAC or ALAC).
    /// Returns the codec alone if the asset format can't be read (e.g. a
    /// still-loading remote stream), so the chip always shows something. Stays on
    /// the MainActor (the async loaders hop off internally) so the non-Sendable
    /// AVAsset never crosses an actor boundary.
    static func formatDetail(from asset: AVAsset, codec: String?) async -> String? {
        var parts: [String] = []
        if let codec, !codec.isEmpty { parts.append(codec) }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let desc = try? await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            let losslessIDs: Set<AudioFormatID> = [
                kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC
            ]
            if losslessIDs.contains(asbd.mFormatID) {
                if asbd.mBitsPerChannel > 0 { parts.append("\(asbd.mBitsPerChannel)-bit") }
                if asbd.mSampleRate > 0 {
                    let khz = asbd.mSampleRate / 1000
                    let label = khz == khz.rounded() ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
                    parts.append(label)
                }
            } else if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                parts.append("\(Int((rate / 1000).rounded())) kbps")
            } else if asbd.mSampleRate > 0 {
                // Bitrate unknown (still-buffering stream) — sample rate beats nothing.
                parts.append(String(format: "%.0f kHz", asbd.mSampleRate / 1000))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Re-apply audio enhancements (EQ mix, ReplayGain/preamp, crossfade volume)
    /// to the CURRENT item live, e.g. when the user changes them in Settings while
    /// a track is playing. Setting `audioMix` on an already-prepared item doesn't
    /// take effect until the item is re-evaluated, so nudge it with an exact
    /// seek-in-place (instant for a local/cached file).
    func enhancementsDidChange() {
        applyVolume()
        syncCrossfadeActive()
        // Refresh the already-preloaded next item's EQ mix too, else it plays its
        // whole duration with the stale mix (gaplessAdvanced skips configureItemAudio).
        if let next = preloadedNextItem { configureItemAudio(next) }
        guard let item = currentPlayerItem else { return }
        let hadMix = item.audioMix != nil
        configureItemAudio(item)
        applyReplayGainVolume(for: item, generation: resolveGeneration)
        // Only force a re-prep when the EQ mix actually went on/off or stayed on
        // (a parameter change) — avoids a needless seek for pure volume tweaks.
        if hadMix || item.audioMix != nil {
            let t = player.currentTime()
            if t.seconds.isFinite { player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) }
        }
    }

    /// Attach duration / status / end-of-item observers to the item that is (or
    /// is becoming) current. Reused by the normal load path and by the gapless
    /// hand-off, so a gaplessly-advanced item gets the same wiring.
    private func attachItemObservers(_ item: AVPlayerItem, generation: Int) {
        let durationAsset = item.asset
        Task { @MainActor in
            // Guard AFTER the load: a slow duration resolve for track A that lands
            // once the user has skipped to B must not stamp A's duration onto B
            // (persisting the wrong duration under B's id). Mirrors the format task.
            guard let cmDuration = try? await durationAsset.load(.duration),
                  generation == self.resolveGeneration else { return }
            let seconds = cmDuration.seconds
            if seconds.isFinite, seconds > 0 {
                self.duration = seconds
                self.updateNowPlayingInfo()
                if self.queue.indices.contains(self.currentIndex) {
                    self.onDurationResolved?(self.queue[self.currentIndex].id, seconds)
                }
            }
        }

        // Codec/bit-depth/sample-rate for the player's format chip. Seed with the
        // file-extension label immediately, then refine from the decoded asset.
        currentFormatDetail = currentTrack?.formatLabel
        let formatAsset = item.asset
        let codec = currentTrack?.fileExtension.uppercased()
        Task { @MainActor in
            guard let detail = await Self.formatDetail(from: formatAsset, codec: codec),
                  generation == self.resolveGeneration else { return }
            self.currentFormatDetail = detail
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
                    // A track genuinely started: clear any prior failure state.
                    self.consecutiveFailureSkips = 0
                    self.lastErrorMessage = nil
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
                    AppLog.playback.debug("BETTERSTREAMING_PLAY ready index=\(self.currentIndex) duration=\(duration)")
                    #endif
                    // Count the play only once the item is genuinely ready.
                    if self.notedPlayGeneration != generation,
                       self.queue.indices.contains(self.currentIndex) {
                        self.notedPlayGeneration = generation
                        self.onTrackStarted?(self.queue[self.currentIndex])
                    }
                    self.preloadNextIfGapless()
                    self.updateNowPlayingInfo()
                case .failed:
                    self.isBuffering = false
                    self.lastErrorMessage = self.player.currentItem?.error?.localizedDescription ?? "Playback failed."
                    let itemError = self.player.currentItem?.error?.localizedDescription ?? "nil"
                    let errLog = self.player.currentItem?.errorLog()?.events.last
                    streamLog.error("item_failed err=\(itemError, privacy: .public) log=\(errLog?.errorStatusCode ?? 0):\(errLog?.errorComment ?? "nil", privacy: .public)")
                    self.handleLoadFailure()
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
    }

    private func loadPlayerItem(item: AVPlayerItem, autoPlay: Bool, generation: Int) {
        endSwitchFade()   // the new item is ready — stop fading, restore volume
        attachItemObservers(item, generation: generation)
        item.preferredForwardBufferDuration = Self.preferredForwardBufferSeconds
        applyEnhancements(to: item, generation: generation)
        // Replace the whole queue with this one item. (AVQueuePlayer's
        // replaceCurrentItem is discouraged; removeAllItems + insert is the
        // supported way to set a single current item.)
        clearPreload()
        player.removeAllItems()
        player.insert(item, after: nil)
        currentPlayerItem = item
        if autoPlay {
            configureAudioSessionIfNeeded()
            player.play()
            isPlaying = true
            #if DEBUG
            let route = AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
            AppLog.playback.debug("BETTERSTREAMING_PLAY player_play route=\(route, privacy: .public) volume=\(AVAudioSession.sharedInstance().outputVolume)")
            #endif
        }
        // onTrackStarted is fired from the .readyToPlay observation, not here,
        // so a track that fails to resolve/play is never counted as a play.
        updateNowPlayingInfo()
    }

    /// When set (sleep timer "end of track"), playback pauses at the end of the
    /// current track instead of advancing — so drop any gapless preload that
    /// would otherwise carry it straight into the next track.
    var stopAtTrackEnd = false {
        didSet { if stopAtTrackEnd { clearPreload() } }
    }

    private func handlePlaybackEnded() {
        // Gapless: AVQueuePlayer already advanced to the preloaded next item. Do
        // the bookkeeping instead of a fresh resolve (which would re-gap it).
        if let next = preloadedNextItem, let idx = preloadedNextIndex, player.currentItem === next {
            if stopAtTrackEnd {
                // Sleep "end of track": the preload shouldn't have happened, but if
                // it did, stop on the new item's first frame.
                stopAtTrackEnd = false
                clearPreload()
                pause()
                return
            }
            gaplessAdvanced(to: next, index: idx)
            return
        }
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
            handleLoadFailure()
            return
        }
        advance(userInitiated: false)
    }

    private func advance(userInitiated: Bool) {
        // A user tapping Next while paused advances without force-playing (mirrors
        // previous()); an auto-advance at track end keeps playback rolling.
        let autoPlay = userInitiated ? isPlaying : true
        if currentIndex < queue.count - 1 {
            currentIndex += 1
            startCurrentItem(autoPlay: autoPlay, automaticAdvance: !userInitiated)
        } else if repeatMode == .all, !queue.isEmpty {
            currentIndex = 0
            startCurrentItem(autoPlay: autoPlay, automaticAdvance: !userInitiated)
        } else {
            // Reached the end of the queue.
            isPlaying = false
            player.pause()
            seek(toSeconds: 0)
        }
    }

    /// A track that failed to resolve/play. When it was reached by a non-user
    /// auto-advance and we haven't skipped too many in a row, skip forward to the
    /// next track (unattended playback shouldn't halt on one dead file mid-queue);
    /// otherwise stop and keep the failed selection visible.
    private func handleLoadFailure() {
        let hasNext = currentIndex < queue.count - 1 || (repeatMode == .all && !queue.isEmpty)
        if currentLoadWasAutoAdvance, consecutiveFailureSkips < Self.maxConsecutiveFailureSkips, hasNext {
            consecutiveFailureSkips += 1
            preserveErrorOnNextLoad = true
            advance(userInitiated: false)
        } else {
            stopAfterFailure()
        }
    }

    /// Keep the failed selection visible instead of racing through the queue.
    private func stopAfterFailure() {
        player.pause()
        // Drop the dead/failed item so a later resume() can't play the PREVIOUS
        // track's still-queued audio; resume() re-resolves the current track.
        player.removeAllItems()
        currentPlayerItem = nil
        isPlaying = false
        isBuffering = false
        // A switch-fade may have ramped player.volume toward 0 for the failed
        // load; hand volume back to applyVolume so a retry isn't near-silent.
        endSwitchFade()
        applyVolume()
        #if DEBUG
        AppLog.playback.debug("BETTERSTREAMING_PLAY stop_after_failure message=\(self.lastErrorMessage ?? "nil")")
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
        // 0.1 s (was 0.5): a fine enough tick that the crossfade envelope rolls off
        // smoothly (≈30 steps over a 3 s fade, not 6) and the scrubber moves
        // fluidly. Cheap on-device; the body early-returns unless actually playing.
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
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
                if self.enhancements.crossfadeSeconds > 0.1 { self.applyVolume() }
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
                let wasBuffering = self.isBuffering
                self.isBuffering = (status == .waitingToPlayAtSpecifiedRate) || self.isPrerolling
                // The lock-screen playback rate depends on isBuffering; push a fresh
                // Now Playing update when it flips so the system clock stops/starts.
                if self.isBuffering != wasBuffering { self.updateNowPlayingInfo() }
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

    /// Output ports that, when yanked, should pause playback (the "unplug the
    /// headphones, don't blast the speaker" behaviour).
    private static let headphoneOutputPorts: Set<AVAudioSession.Port> = [
        .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP
    ]

    private func observeRouteChanges() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let previousRoute = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reasonValue: reasonValue, previousRoute: previousRoute)
            }
        }
    }

    private func handleRouteChange(reasonValue: UInt?, previousRoute: AVAudioSessionRouteDescription?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
              reason == .oldDeviceUnavailable else { return }
        // Only pause when the route we LOST was headphones/BT. iOS already pauses
        // the player, but never flips our `isPlaying`, so the transport icon and
        // lock screen desync; going through `pause()` keeps them in sync.
        let lostHeadphones = (previousRoute?.outputs ?? []).contains {
            Self.headphoneOutputPorts.contains($0.portType)
        }
        guard lostHeadphones, isPlaying else { return }
        pause()
    }

    private func observeMediaServicesReset() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMediaServicesReset()
            }
        }
    }

    private func handleMediaServicesReset() {
        // mediaserverd crashed and restarted: the audio session is torn down and
        // every AVPlayerItem is dead. Force a fresh session configure and rebuild
        // the current item, preserving position and the user's play/pause intent.
        audioSessionConfigured = false
        guard currentTrack != nil else { return }
        let wasPlaying = isPlaying
        startCurrentItem(autoPlay: wasPlaying, resumeAt: elapsed)
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
            // Report 0 while buffering so the lock-screen clock doesn't tick ahead of
            // stalled audio; it resumes to 1.0 once playback actually rolls.
            MPNowPlayingInfoPropertyPlaybackRate: (isPlaying && !isBuffering) ? 1.0 : 0.0
        ]
        if let art = currentArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork(for: art)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// The last-built artwork wrapper and the image it wraps. updateNowPlayingInfo
    /// runs on many transport events; rebuilding the (retained-closure) wrapper
    /// each time is wasteful, so reuse it while the underlying image is unchanged.
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkImage: UIImage?

    private func nowPlayingArtwork(for image: UIImage) -> MPMediaItemArtwork {
        if let cachedArtwork, cachedArtworkImage === image { return cachedArtwork }
        let artwork = Self.nowPlayingArtwork(from: image)
        cachedArtwork = artwork
        cachedArtworkImage = image
        return artwork
    }

    private func clearArtworkCache() {
        cachedArtwork = nil
        cachedArtworkImage = nil
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
