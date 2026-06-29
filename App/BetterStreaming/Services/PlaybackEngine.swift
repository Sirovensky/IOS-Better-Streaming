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
        for index in safe.sorted(by: >) { queue.remove(at: index) }
        currentIndex -= removedBeforeCurrent
    }

    func moveQueueItem(fromOffsets source: IndexSet, toOffset destination: Int) {
        let current = currentTrack
        queue.move(fromOffsets: source, toOffset: destination)
        if let current, let newIndex = queue.firstIndex(of: current) {
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
        configureAudioSessionIfNeeded()
        player.play()
        isPlaying = true
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
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
        let clamped = min(max(seconds, 0), max(duration, 0))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsed = clamped
                self.updateNowPlayingInfo()
            }
        }
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
            if let current, let idx = queue.firstIndex(of: current) {
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

    private func startCurrentItem(autoPlay: Bool) {
        guard let track = currentTrack else { return }
        #if DEBUG
        print("BETTERSTREAMING_PLAY start title=\(track.title) ext=\(track.fileExtension) source=\(track.sourceID) remote=\(track.remotePath ?? "nil")")
        #endif
        resolveGeneration += 1
        let generation = resolveGeneration
        isBuffering = true
        elapsed = 0
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
                if seconds.isFinite { self.elapsed = seconds }
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
                // so the UI can show activity instead of looking frozen.
                self.isBuffering = (status == .waitingToPlayAtSpecifiedRate)
                streamLog.info("timeControl=\(status.rawValue) reason=\(reason, privacy: .public) elapsed=\(self.elapsed)")
            }
        }
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
