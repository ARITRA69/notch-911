import Foundation
import Testing
@testable import notch_911

/// Every claim here runs against a scratch path, never the real lock file —
/// the developer's own running copy usually holds that one, and a test must
/// not be able to unseat it (or be failed by it).
@Suite("Single-instance lock")
@MainActor
struct SingleInstanceTests {

    private static func scratchLock() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-911-instance-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("instance.lock", isDirectory: false)
    }

    @Test func firstClaimWins() {
        guard case .primary(let lock) = SingleInstance.claim(at: Self.scratchLock()) else {
            Issue.record("first claim should acquire the lock")
            return
        }
        #expect(lock != nil)
    }

    @Test func secondClaimDefersToTheHolder() {
        let url = Self.scratchLock()
        guard case .primary(let lock) = SingleInstance.claim(at: url), lock != nil else {
            Issue.record("first claim should acquire the lock")
            return
        }
        // flock contention is per open-file-description, not per process, so
        // a second claim from this process contends exactly like a second
        // process would.
        guard case .deferred(let holder) = SingleInstance.claim(at: url) else {
            Issue.record("second claim should defer while the lock is held")
            return
        }
        #expect(holder == ProcessInfo.processInfo.processIdentifier)
        withExtendedLifetime(lock) {}
    }

    @Test func releasedLockLetsTheNextClaimThrough() {
        let url = Self.scratchLock()
        var outcome = SingleInstance.claim(at: url)
        guard case .primary(.some) = outcome else {
            Issue.record("first claim should acquire the lock")
            return
        }
        // Dropping the token closes the descriptor, which releases the flock
        // exactly as a process exit would.
        outcome = .primary(nil)
        guard case .primary(.some) = SingleInstance.claim(at: url) else {
            Issue.record("claim after release should acquire the lock")
            return
        }
    }
}
