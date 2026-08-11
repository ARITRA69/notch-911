//
//  SingleInstance.swift
//  notch-911
//
//  One notch, one process. Two copies of this app running at once both draw
//  a surface over the notch, both register ⇧⌘V (the first silently wins), and
//  both run hover sensors — the visible symptom is a "broken" collapse, with
//  the losing copy's black slab sitting underneath the animating one. The
//  install script's backup copies carry historical bundle identifiers, so a
//  bundle-id check alone cannot see them; the arbiter has to be something
//  every copy shares. `flock(2)` on a file in the app's Application Support
//  directory is that: the first process in takes it, the kernel drops it the
//  instant that process dies, and there is no stale-pid cleanup to get wrong.
//

import AppKit

enum SingleInstance {

    /// Owning handle for the lock, held by the app delegate for the process
    /// lifetime. If it is ever released, the descriptor closes and the next
    /// launch walks straight in.
    final class Lock {
        fileprivate let descriptor: CInt
        fileprivate init(descriptor: CInt) { self.descriptor = descriptor }
        deinit { close(descriptor) }
    }

    enum Outcome {
        /// This process is the app's one instance. The lock is nil only when
        /// the file could not be created at all — failing open beats refusing
        /// to launch over an infrastructure problem, and the pre-guard
        /// behaviour was no protection either.
        case primary(Lock?)
        /// Another process already holds the lock — its pid when readable.
        case deferred(to: pid_t?)
    }

    static func claim() -> Outcome {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return .primary(nil) }
        return claim(at: support
            .appendingPathComponent("notch-911", isDirectory: true)
            .appendingPathComponent("instance.lock", isDirectory: false))
    }

    /// Split out so tests can arbitrate over a scratch file instead of the
    /// real one, which the developer's own running copy usually holds.
    static func claim(at url: URL) -> Outcome {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // O_EXLOCK makes open-and-flock one atomic step; O_NONBLOCK turns
        // "someone else holds it" into an immediate EWOULDBLOCK instead of a
        // wait behind a healthy instance.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXLOCK | O_NONBLOCK, 0o644)
        if descriptor >= 0 {
            // Advisory content only — it lets the losing copy find whom to
            // activate. The lock itself never depends on what is in the file.
            ftruncate(descriptor, 0)
            "\(ProcessInfo.processInfo.processIdentifier)".withCString {
                _ = write(descriptor, $0, strlen($0))
            }
            return .primary(Lock(descriptor: descriptor))
        }
        guard errno == EWOULDBLOCK else { return .primary(nil) }
        return .deferred(to: holderPID(at: url))
    }

    /// Bring the copy that owns the notch to the front, so double-clicking a
    /// second copy still ends with the user looking at the app.
    static func activateExistingInstance(_ pid: pid_t?) {
        let running = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                    && $0.executableURL?.lastPathComponent == "notch-911"
            }
        running?.activate()
    }

    private static func holderPID(at url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
