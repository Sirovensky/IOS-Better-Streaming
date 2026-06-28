import Foundation
import Testing
import BetterStreamingDomain
import PlaybackCore

@Test func queueSnapshotDefaultsToRepeatOff() {
    let snapshot = PlaybackQueueSnapshot()
    #expect(snapshot.repeatMode == .off)
    #expect(snapshot.currentItem == nil)
}

@Test func loadQueueStartsAtRequestedItem() async throws {
    let ids = [MediaItemID(), MediaItemID(), MediaItemID()]
    let controller = PlaybackController()

    try await controller.load(.items(ids), startAt: ids[1])
    let snapshot = await controller.snapshot()

    #expect(snapshot.currentIndex == 1)
    #expect(snapshot.currentItem?.mediaItemID == ids[1])
}

@Test func playNextInsertsAfterCurrentItem() async throws {
    let ids = [MediaItemID(), MediaItemID(), MediaItemID()]
    let controller = PlaybackController()

    try await controller.load(.items([ids[0], ids[2]]), startAt: ids[0])
    try await controller.playNext([ids[1]])
    let snapshot = await controller.snapshot()

    #expect(snapshot.items.map(\.mediaItemID) == ids)
    #expect(snapshot.currentItem?.mediaItemID == ids[0])
}

@Test func repeatAllWrapsToFirstItem() {
    let next = PlaybackController.nextIndex(
        from: 2,
        count: 3,
        repeatMode: .all,
        reason: .itemFinished
    )

    #expect(next == 0)
}

@Test func repeatOneRepeatsOnlyWhenItemFinishes() {
    let finished = PlaybackController.nextIndex(
        from: 1,
        count: 3,
        repeatMode: .one,
        reason: .itemFinished
    )
    let userSkip = PlaybackController.nextIndex(
        from: 1,
        count: 3,
        repeatMode: .one,
        reason: .userInitiated
    )

    #expect(finished == 1)
    #expect(userSkip == 2)
}

@Test func skipToNextStopsAtEndWhenRepeatIsOff() async throws {
    let ids = [MediaItemID(), MediaItemID()]
    let controller = PlaybackController()

    try await controller.load(.items(ids), startAt: ids[1])
    try await controller.skipToNext()
    let snapshot = await controller.snapshot()
    let state = await controller.transportState()

    #expect(snapshot.currentItem == nil)
    #expect(state == .idle)
}

@Test func deterministicShuffleKeepsStoredOrderStable() async throws {
    let items = [
        QueueItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, mediaItemID: MediaItemID()),
        QueueItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, mediaItemID: MediaItemID()),
        QueueItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, mediaItemID: MediaItemID()),
        QueueItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, mediaItemID: MediaItemID())
    ]
    let first = PlaybackController.deterministicallyShuffled(items, seed: ShuffleSeed(1234))
    let second = PlaybackController.deterministicallyShuffled(items, seed: ShuffleSeed(1234))
    let differentSeed = PlaybackController.deterministicallyShuffled(items, seed: ShuffleSeed(9999))

    #expect(first.map(\.id) == second.map(\.id))
    #expect(first.map(\.id) != items.map(\.id))
    #expect(first.map(\.id) != differentSeed.map(\.id))
}

@Test func reorderPreservesCurrentItemIdentity() async throws {
    let ids = [MediaItemID(), MediaItemID(), MediaItemID()]
    let controller = PlaybackController()

    try await controller.load(.items(ids), startAt: ids[1])
    try await controller.reorder(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    let snapshot = await controller.snapshot()

    #expect(snapshot.items.map(\.mediaItemID) == [ids[1], ids[2], ids[0]])
    #expect(snapshot.currentItem?.mediaItemID == ids[1])
}
