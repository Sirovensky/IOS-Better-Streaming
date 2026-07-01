import Foundation
import Observation

/// Per-track listening statistics used to score the auto-cache hot set.
struct PlayStat: Codable, Sendable {
    var playCount: Int = 0
    var lastPlayedAtEpoch: Double = 0
    /// First time we ever saw a play, used to damp brand-new bulk-played items.
    var firstPlayedAtEpoch: Double = 0
}

/// A single timestamped play, used for windowed stats ("top this month") that the
/// per-track aggregate `PlayStat` can't answer (it only keeps the latest play time).
/// Kept bounded (most-recent N) so it stays cheap in UserDefaults.
struct PlayEvent: Codable, Sendable {
    var id: String
    var at: Double
}

/// A single decision produced by the reconciler.
struct CachePlan: Sendable {
    /// Tracks that should be fetched/kept (in priority order).
    var keep: [String]
    /// Currently-cached tracks that should be evicted to stay under budget.
    var evict: [String]
    var projectedBytes: Int64
    var budgetBytes: Int64
}

/// Decides which tracks to keep warm in the offline cache automatically.
///
/// The core problem (ask #7): a user who listens to one big playlist once should
/// not have it evict the handful of songs they actually return to. So the score
/// blends *frequency* (play count, log-damped) with *recency* (exponential
/// decay), and favourites / manual downloads are never auto-evicted. The
/// controller owns the policy and persists stats; the actual byte transfer is
/// performed by whatever `applyPlan` is wired to (CacheManager on device).
@Observable
@MainActor
final class AutoCacheController {
    // MARK: Settings (persisted)

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }
    /// Maximum bytes the auto-cache may use. Manual downloads are tracked
    /// separately and are not bound by this budget.
    var budgetBytes: Int64 {
        didSet { defaults.set(budgetBytes, forKey: Keys.budget) }
    }
    var protectFavorites: Bool {
        didSet { defaults.set(protectFavorites, forKey: Keys.protectFavorites) }
    }
    /// Only auto-cache while on Wi-Fi (advisory flag surfaced in Settings; the
    /// reachability check itself is done by the caller before reconciling).
    var wifiOnly: Bool {
        didSet { defaults.set(wifiOnly, forKey: Keys.wifiOnly) }
    }

    /// Budget presets offered in Settings, in bytes. Decimal GB so the labels
    /// read clean ("5 GB"), matching how ByteCountFormatter(.file) divides.
    static let budgetPresets: [Int64] = [1, 2, 5, 10, 20, 50].map { $0 * 1_000_000_000 }

    // MARK: Observed runtime state

    private(set) var autoCachedBytes: Int64 = 0
    private(set) var lastReconcileSummary: String = "Idle"

    // MARK: Dependencies

    /// Performs the actual fetch/evict. Returns the set of track IDs that are now
    /// cached so the controller can update its usage accounting. On device this
    /// is backed by CacheManager; in the demo it just flips cacheState.
    var applyPlan: (@MainActor (CachePlan) async -> Void)?

    // MARK: Private

    private let defaults: UserDefaults
    private var stats: [String: PlayStat]
    /// Bounded most-recent play log for windowed stats. Capped at `maxPlayEvents`.
    private var playEvents: [PlayEvent]
    private static let maxPlayEvents = 8000
    private var reconcileTask: Task<Void, Never>?

    private enum Keys {
        static let enabled = "autocache.enabled.v1"
        static let budget = "autocache.budgetBytes.v1"
        static let protectFavorites = "autocache.protectFavorites.v1"
        static let wifiOnly = "autocache.wifiOnly.v1"
        static let stats = "autocache.stats.v1"
        static let playEvents = "autocache.playEvents.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        // Snap any legacy/non-preset stored value (e.g. old GiB 5<<30) to a clean preset.
        let storedBudget = defaults.object(forKey: Keys.budget) as? Int64
        self.budgetBytes = (storedBudget.flatMap { Self.budgetPresets.contains($0) ? $0 : nil }) ?? 5_000_000_000
        self.protectFavorites = defaults.object(forKey: Keys.protectFavorites) as? Bool ?? true
        self.wifiOnly = defaults.object(forKey: Keys.wifiOnly) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.stats),
           let decoded = try? JSONDecoder().decode([String: PlayStat].self, from: data) {
            self.stats = decoded
        } else {
            self.stats = [:]
        }
        if let data = defaults.data(forKey: Keys.playEvents),
           let decoded = try? JSONDecoder().decode([PlayEvent].self, from: data) {
            self.playEvents = decoded
        } else {
            self.playEvents = []
        }
    }

    // MARK: Play tracking

    /// Record that a track started playing. Called by PlaybackEngine.onTrackStarted.
    func recordPlay(_ trackID: String, now: Date = Date()) {
        let epoch = now.timeIntervalSince1970
        var stat = stats[trackID] ?? PlayStat()
        stat.playCount += 1
        stat.lastPlayedAtEpoch = epoch
        if stat.firstPlayedAtEpoch == 0 { stat.firstPlayedAtEpoch = epoch }
        stats[trackID] = stat
        playEvents.append(PlayEvent(id: trackID, at: epoch))
        if playEvents.count > Self.maxPlayEvents {
            playEvents.removeFirst(playEvents.count - Self.maxPlayEvents)
        }
        persistStatsSoon()
    }

    /// Coalesce stats writes — a play used to JSON-encode + write the whole stats
    /// dict synchronously every track. Flushed on app background (see flushStats).
    private var persistTask: Task<Void, Never>?
    private func persistStatsSoon() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistStats()
        }
    }

    /// Flush a pending debounced stats write now (call when backgrounding so an
    /// OS-kill while suspended doesn't drop the last few plays).
    func flushStats() {
        persistTask?.cancel()
        persistStats()
    }

    func stat(for trackID: String) -> PlayStat { stats[trackID] ?? PlayStat() }

    /// A track whose whole play history fits inside this window counts as a single
    /// bulk session (a playlist played straight through), not a track the user
    /// keeps returning to.
    private static let bulkSessionSeconds: Double = 30 * 60
    /// Score multiplier applied to bulk-played-once tracks. Conservative: keeps them
    /// in contention but below tracks with plays spread over time.
    private static let bulkPlayDamping: Double = 0.7

    /// Frequency + recency score. Higher = keep.
    func score(for trackID: String, now: Date = Date()) -> Double {
        guard let stat = stats[trackID], stat.playCount > 0 else { return 0 }
        // Frequency: log-damped so a 50-play favourite doesn't dwarf everything,
        // but a 1-play bulk track stays low.
        let frequency = log2(Double(stat.playCount) + 1)
        // Recency: exponential decay with a 14-day half-life.
        let ageSeconds = max(now.timeIntervalSince1970 - stat.lastPlayedAtEpoch, 0)
        let halfLifeSeconds = 14.0 * 24 * 3600
        let recency = pow(0.5, ageSeconds / halfLifeSeconds)
        // Weighted blend. Frequency dominates so returning listens beat one-offs.
        var score = frequency * 1.6 + recency * 1.0
        // Damp bulk-played-once items: when every play landed in one short session,
        // it's likely a playlist played once, so discount it so genuine repeats
        // (plays spread across sessions) outrank it.
        if stat.firstPlayedAtEpoch > 0 {
            let span = stat.lastPlayedAtEpoch - stat.firstPlayedAtEpoch
            if span >= 0, span < Self.bulkSessionSeconds {
                score *= Self.bulkPlayDamping
            }
        }
        return score
    }

    /// Track IDs played most in the last `sinceDays`, most-played first. Backs the
    /// "Top this month" shelf, which the per-track `PlayStat` aggregate can't
    /// answer because it only stores the latest play time, not a windowed count.
    func topPlayed(sinceDays: Int, limit: Int, now: Date = Date()) -> [String] {
        let cutoff = now.timeIntervalSince1970 - Double(sinceDays) * 24 * 3600
        var counts: [String: Int] = [:]
        for event in playEvents where event.at >= cutoff {
            counts[event.id, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }

    // MARK: Reconciliation

    /// Recompute the desired hot set from the current library and schedule the
    /// fetch/evict. Debounced; safe to call frequently (e.g. after each play).
    func scheduleReconcile(library: [Track], reachable: Bool) {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.reconcile(library: library, reachable: reachable)
        }
    }

    func reconcile(library: [Track], reachable: Bool, now: Date = Date()) async {
        guard isEnabled else {
            lastReconcileSummary = "Auto-cache off"
            return
        }
        guard reachable else {
            lastReconcileSummary = "Source offline — kept current cache"
            return
        }

        let plan = makePlan(library: library, now: now)
        // A rapid re-schedule cancels reconcileTask, which cancels this awaiting
        // call. Bail before the heavy fetch/evict (and again before clobbering the
        // summary) so a superseded run can't double-apply over the newer one.
        if Task.isCancelled { return }
        autoCachedBytes = plan.projectedBytes
        await applyPlan?(plan)   // applyPlan reports real on-disk usage via setUsage
        if Task.isCancelled { return }
        lastReconcileSummary = "Keeping \(plan.keep.count) songs · \(Self.byteLabel(autoCachedBytes)) of \(Self.byteLabel(budgetBytes))"
    }

    /// Report actual on-disk usage after a plan applies (overrides the estimate).
    func setUsage(_ bytes: Int64) { autoCachedBytes = bytes }

    /// Pure planning function (unit-testable): pick the highest-scoring tracks
    /// that fit the budget, and evict everything currently auto-cached that
    /// didn't make the cut.
    func makePlan(library: [Track], now: Date = Date()) -> CachePlan {
        // Candidates worth caching: ones with any listening history.
        let scored = library
            .map { ($0, score(for: $0.id, now: now)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }

        var keep: [String] = []
        var used: Int64 = 0

        // Favourites are kept warm first, but still bounded by the budget so a
        // large favourited library can't fill the device. Highest-scored (most
        // recently/often played) favourites win the available space.
        if protectFavorites {
            let favorites = library
                .filter { $0.isFavorite }
                .sorted { score(for: $0.id, now: now) > score(for: $1.id, now: now) }
            for track in favorites {
                let size = bytesEstimate(for: track)
                if used + size > budgetBytes { continue }
                keep.append(track.id)
                used += size
            }
        }

        for (track, _) in scored {
            if keep.contains(track.id) { continue }
            let size = bytesEstimate(for: track)
            if used + size > budgetBytes { continue }
            keep.append(track.id)
            used += size
        }

        let keepSet = Set(keep)
        // Evict tracks that the auto-cache previously held but are no longer in
        // the hot set. Manual downloads use `.cached`; auto-cache uses `.prefetched`.
        let evict = library
            .filter { $0.cacheState == .prefetched && !keepSet.contains($0.id) }
            .map(\.id)

        return CachePlan(keep: keep, evict: evict, projectedBytes: used, budgetBytes: budgetBytes)
    }

    /// Prefer scan-provided file size. Duration is only a fallback for sources
    /// that cannot report sizes yet.
    func bytesEstimate(for track: Track) -> Int64 {
        if let size = track.sizeBytes, size > 0 { return size }
        if track.durationSeconds <= 0 { return 5_000_000 }
        let bytesPerSecond: Double = 256_000 / 8
        return Int64(track.durationSeconds * bytesPerSecond)
    }

    // MARK: Persistence

    private func persistStats() {
        if let data = try? JSONEncoder().encode(stats) {
            defaults.set(data, forKey: Keys.stats)
        }
        if let data = try? JSONEncoder().encode(playEvents) {
            defaults.set(data, forKey: Keys.playEvents)
        }
    }

    func resetStats() {
        stats = [:]
        playEvents = []
        persistStats()
        autoCachedBytes = 0
        lastReconcileSummary = "Listening history cleared"
    }

    // MARK: Formatting

    static func byteLabel(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
