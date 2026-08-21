//
//  CodexCompletionWatcher.swift
//  notch-911
//
//  Codex's turn-completion signal never reaches us as a hook. Its `Stop` hook
//  is registered in ~/.codex/hooks.json like Claude Code's, but Codex has never
//  once executed it on this machine — its own `hook_runtime` logger has zero
//  entries against 21k rows of other logging — so anything that waits on that
//  hook waits forever.
//
//  The rollout logs it writes for itself are a different matter. Every turn
//  closes with an `event_msg` / `task_complete` record carrying `turn_id`,
//  `last_agent_message` and `duration_ms`, which is strictly more than the hook
//  would have given us. Same observe-don't-own posture as
//  `CodexPlanQuestionWatcher`: read the files, never write them.
//

import Foundation

nonisolated struct CodexCompletion: Sendable {
    let turnID: String
    let sessionID: String
    let cwd: String
    let lastAgentMessage: String
    let duration: TimeInterval?
    let completedAt: Date
}

/// File work stays off the main actor. Only rollouts whose mtime moved are
/// reparsed, so the steady-state cost is one small directory listing.
actor CodexCompletionWatcher {

    private struct FileSnapshot {
        let modifiedAt: Date
        let completions: [CodexCompletion]
    }

    private let sessionsRoot: URL
    private var files: [String: FileSnapshot] = [:]
    private var delivered: Set<String> = []
    private var hasPolled = false

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        sessionsRoot = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Completions recorded since the last poll, oldest first.
    func poll(now: Date = Date()) -> [CodexCompletion] {
        let manager = FileManager.default
        let candidates = recentRollouts(now: now, manager: manager)
        let paths = Set(candidates.map(\.path))

        for stale in files.keys where !paths.contains(stale) {
            files.removeValue(forKey: stale)
        }

        for url in candidates {
            guard let attributes = try? manager.attributesOfItem(atPath: url.path),
                  let modifiedAt = attributes[.modificationDate] as? Date
            else { continue }
            if files[url.path]?.modifiedAt == modifiedAt { continue }
            files[url.path] = FileSnapshot(modifiedAt: modifiedAt, completions: parse(url: url))
        }

        let all = files.values.flatMap(\.completions)

        // First poll is a baseline, never an announcement. Today's rollouts are
        // full of turns that finished before the app launched, and replaying
        // them as a burst of banners is the one behaviour that would make this
        // feature worth switching off.
        if !hasPolled {
            hasPolled = true
            delivered.formUnion(all.map(\.turnID))
            return []
        }

        let fresh = all
            .filter { !delivered.contains($0.turnID) }
            .sorted { $0.completedAt < $1.completedAt }
        delivered.formUnion(fresh.map(\.turnID))
        return fresh
    }

    /// Today and yesterday, so a turn that lands either side of midnight is
    /// still found. Anything older can't be news.
    private func recentRollouts(now: Date, manager: FileManager) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        var result: [URL] = []

        for dayOffset in [0, -1] {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let directory = sessionsRoot
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            guard let urls = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            result.append(contentsOf: urls.filter { $0.pathExtension == "jsonl" })
        }
        return result
    }

    private func parse(url: URL) -> [CodexCompletion] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [] }

        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var completions: [CodexCompletion] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = root["payload"] as? [String: Any]
            else { continue }

            switch root["type"] as? String {
            case "session_meta":
                sessionID = payload["id"] as? String ?? sessionID
                cwd = payload["cwd"] as? String ?? cwd
                continue
            case "turn_context":
                cwd = payload["cwd"] as? String ?? cwd
                continue
            case "event_msg":
                break
            default:
                continue
            }

            guard payload["type"] as? String == "task_complete",
                  let turnID = payload["turn_id"] as? String, !turnID.isEmpty
            else { continue }

            // `completed_at` is whole seconds since the epoch. The record's own
            // ISO timestamp is the fallback, and only then the wall clock —
            // ordering across files depends on this being the turn's time and
            // not the time we happened to read it.
            let completedAt: Date
            if let seconds = payload["completed_at"] as? Double {
                completedAt = Date(timeIntervalSince1970: seconds)
            } else if let stamp = (root["timestamp"] as? String).flatMap(Self.parseDate) {
                completedAt = stamp
            } else {
                completedAt = Date()
            }

            let duration = (payload["duration_ms"] as? Double).map { $0 / 1000 }

            completions.append(
                CodexCompletion(
                    turnID: turnID,
                    sessionID: sessionID,
                    cwd: cwd,
                    lastAgentMessage: (payload["last_agent_message"] as? String) ?? "",
                    duration: duration,
                    completedAt: completedAt
                )
            )
        }

        return completions
    }

    private nonisolated static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
