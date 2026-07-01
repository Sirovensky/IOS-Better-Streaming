import XCTest
@testable import BetterStreaming

/// Unit tests for the auto-cache policy — the one piece of app-target logic that is
/// pure and deterministic (every method takes an injectable `now:`), and the one
/// that shipped a real scoring bug. Covers scoring order, bulk-play damping, and the
/// keep/evict planner so a regression here can't silently mis-cache the library.
@MainActor
final class AutoCacheControllerTests: XCTestCase {
    private func makeController() -> AutoCacheController {
        // Isolated defaults per test so persisted stats never leak between cases.
        let defaults = UserDefaults(suiteName: "autocache-test-\(UUID().uuidString)")!
        return AutoCacheController(defaults: defaults)
    }

    private func track(
        _ id: String,
        favorite: Bool = false,
        cacheState: CacheState = .remoteOnly,
        sizeBytes: Int64? = 4_000_000
    ) -> Track {
        Track(id: id, title: id, artist: "A", album: "Album", durationSeconds: 200,
              cacheState: cacheState, isFavorite: favorite, sourceID: "s", sourceName: "S",
              folderPath: "/\(id)", sizeBytes: sizeBytes)
    }

    private func date(_ epoch: Double) -> Date { Date(timeIntervalSince1970: epoch) }

    func testUnplayedTrackScoresZero() {
        XCTAssertEqual(makeController().score(for: "never-played"), 0)
    }

    func testMorePlaysScoreHigher() {
        let c = makeController()
        let now = date(1_000_000)
        // "hot" played across five days ending now; "cold" once.
        for d in stride(from: 4.0, through: 0, by: -1) {
            c.recordPlay("hot", now: date(now.timeIntervalSince1970 - d * 86_400))
        }
        c.recordPlay("cold", now: now)
        XCTAssertGreaterThan(c.score(for: "hot", now: now), c.score(for: "cold", now: now))
    }

    func testRecentBeatsStaleAtEqualPlays() {
        let c = makeController()
        let now = date(2_000_000)
        c.recordPlay("recent", now: now)
        c.recordPlay("stale", now: date(now.timeIntervalSince1970 - 60 * 86_400))
        XCTAssertGreaterThan(c.score(for: "recent", now: now), c.score(for: "stale", now: now))
    }

    func testBulkPlayedOnceIsDampedBelowSpreadPlays() {
        let c = makeController()
        let now = date(3_000_000)
        // Same play count (3), but "bulk" all landed in one ~10-min sitting while
        // "spread" is spaced across days — the damping should rank bulk lower.
        c.recordPlay("bulk", now: date(now.timeIntervalSince1970 - 600))
        c.recordPlay("bulk", now: date(now.timeIntervalSince1970 - 300))
        c.recordPlay("bulk", now: now)
        c.recordPlay("spread", now: date(now.timeIntervalSince1970 - 2 * 86_400))
        c.recordPlay("spread", now: date(now.timeIntervalSince1970 - 1 * 86_400))
        c.recordPlay("spread", now: now)
        XCTAssertLessThan(c.score(for: "bulk", now: now), c.score(for: "spread", now: now))
    }

    func testMakePlanKeepsHighestScoringWithinBudget() {
        let c = makeController()
        c.isEnabled = true
        c.protectFavorites = false
        c.budgetBytes = 10_000_000 // fits ~2 of the 4 MB tracks
        let now = date(4_000_000)
        c.recordPlay("a", now: now); c.recordPlay("a", now: now)
        c.recordPlay("b", now: now)
        c.recordPlay("cc", now: now)
        let plan = c.makePlan(library: [track("a"), track("b"), track("cc")], now: now)
        XCTAssertTrue(plan.keep.contains("a"), "most-played track is always kept")
        XCTAssertLessThanOrEqual(plan.projectedBytes, c.budgetBytes)
        XCTAssertLessThanOrEqual(plan.keep.count, 2, "budget bounds the keep set")
    }

    func testMakePlanProtectsFavoritesAndEvictsColdPrefetched() {
        let c = makeController()
        c.isEnabled = true
        c.protectFavorites = true
        c.budgetBytes = 50_000_000
        let now = date(5_000_000)
        c.recordPlay("played", now: now)
        let plan = c.makePlan(library: [
            track("fav", favorite: true),                          // unplayed favourite
            track("played"),
            track("coldPrefetched", cacheState: .prefetched)       // auto-cached, no plays
        ], now: now)
        XCTAssertTrue(plan.keep.contains("fav"), "favourite kept even though never played")
        XCTAssertTrue(plan.evict.contains("coldPrefetched"), "cold auto-cached track is evicted")
    }

    func testBytesEstimatePrefersSizeThenDuration() {
        let c = makeController()
        XCTAssertEqual(c.bytesEstimate(for: track("x", sizeBytes: 123)), 123)
        // No size → duration * 256 kbps: 200 s * 32000 B/s.
        XCTAssertEqual(c.bytesEstimate(for: track("y", sizeBytes: nil)), Int64(200 * 32_000))
    }

    func testTopPlayedIsWindowed() {
        let c = makeController()
        let now = date(6_000_000)
        c.recordPlay("recent", now: date(now.timeIntervalSince1970 - 5 * 86_400))
        c.recordPlay("recent", now: date(now.timeIntervalSince1970 - 5 * 86_400))
        c.recordPlay("old", now: date(now.timeIntervalSince1970 - 40 * 86_400))
        let top = c.topPlayed(sinceDays: 30, limit: 10, now: now)
        XCTAssertEqual(top.first, "recent")
        XCTAssertFalse(top.contains("old"), "plays outside the window are excluded")
    }
}
