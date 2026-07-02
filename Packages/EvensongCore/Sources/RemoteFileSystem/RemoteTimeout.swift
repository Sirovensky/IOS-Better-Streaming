import Foundation
import EvensongDomain

/// One-shot gate: when a continuation is raced between two tasks (the real op
/// and a timeout), this ensures it is resumed exactly once.
public final class RemoteResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    public init() {}

    public func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

public enum RemoteTimeout {
    /// Race `op` against a wall-clock timeout WITHOUT relying on cancellation of
    /// the underlying work (NWConnection / Citadel honour no cancellation on a
    /// wedged receive). The op runs in an UNSTRUCTURED task so that, on timeout,
    /// this returns while the op is left to unwind on its own once its connection
    /// is torn down — a structured group would instead block awaiting the hung
    /// child. On a win the losing sleeper is cancelled immediately so it doesn't
    /// linger for the full duration.
    public static func run<T: Sendable>(
        _ nanoseconds: UInt64,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = RemoteResumeGate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let sleeper = Task {
                try? await Task.sleep(nanoseconds: nanoseconds)
                if gate.tryResume() { continuation.resume(throwing: RemoteFileSystemError.timeout) }
            }
            Task {
                do {
                    let value = try await op()
                    if gate.tryResume() {
                        sleeper.cancel()
                        continuation.resume(returning: value)
                    }
                } catch {
                    if gate.tryResume() {
                        sleeper.cancel()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
