import Foundation
import Testing
import BetterStreamingDomain
import RemoteFileSystem

/// A fake op that never completes — models a wedged NWConnection/Citadel receive
/// that returns no data and never throws. Its continuation is intentionally
/// dropped so the op stays suspended forever; only the timeout can win.
private func hangForever() async throws -> Int {
    try await withCheckedThrowingContinuation { (_: CheckedContinuation<Int, Error>) in
        // Never resumed.
    }
}

private struct SampleError: Error, Equatable {}

@Test func remoteTimeoutTripsOnAHungOperation() async {
    do {
        _ = try await RemoteTimeout.run(20_000_000) {   // 20 ms
            try await hangForever()
        }
        Issue.record("expected a timeout, but the op returned")
    } catch let error as RemoteFileSystemError {
        #expect(error == .timeout)
    } catch {
        Issue.record("expected RemoteFileSystemError.timeout, got \(error)")
    }
}

@Test func remoteTimeoutReturnsAFastValueBeforeTheDeadline() async throws {
    let value = try await RemoteTimeout.run(10_000_000_000) { 42 }   // 10 s ceiling, instant op
    #expect(value == 42)
}

@Test func remoteTimeoutPropagatesTheOpsOwnError() async {
    do {
        _ = try await RemoteTimeout.run(10_000_000_000) { () async throws -> Int in
            throw SampleError()
        }
        Issue.record("expected the op's error to propagate")
    } catch let error as RemoteFileSystemError {
        Issue.record("op error was wrongly mapped to \(error)")
    } catch {
        #expect(error is SampleError)
    }
}

/// The fast path must resolve promptly (the sleeper is cancelled on the win), not
/// linger for anywhere near the ceiling.
@Test func remoteTimeoutFastPathDoesNotWaitForTheCeiling() async throws {
    let start = ContinuousClock.now
    _ = try await RemoteTimeout.run(5_000_000_000) { 1 }   // 5 s ceiling
    let elapsed = ContinuousClock.now - start
    #expect(elapsed < .seconds(1))
}
