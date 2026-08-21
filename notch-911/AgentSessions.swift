//
//  AgentSessions.swift
//  notch-911
//
//  Who is working, and where. Until now the app knew an agent existed only
//  while one of its hook requests was blocked on our socket — `Prompt.sessionId`
//  was parsed and never read. That is enough to answer a question and nothing
//  else: you could not see what was running, and there was no stable thing to
//  hang a per-session setting off.
//
//  Both agents already keep a local record of every session, and both are read
//  the same way `CodexPlanQuestionWatcher` reads its rollouts — by looking, not
//  by joining in:
//
//    ~/.claude/projects/<slugified-cwd>/<sessionId>.jsonl
//    ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
//
//  Nothing here writes to either. Nothing here reads message content: the
//  parsers pull session id, cwd, branch, mode and a timestamp, and skip the
//  rest of every record they touch.
//
//  §7.2 — parsing never happens during animation. The scan is an actor, hands
//  back a finished array, and the store swaps it in on the main actor.
//
//  Idle cost is a hard requirement (README: the app does nothing when idle, and
//  the clipboard's changeCount read is the one grudging exception). So there is
//  no watcher and no background timer here. `setVisible(_:)` starts the poll
//  when the Agents tab is on screen and stops it when it goes away, exactly as
//  `MediaMonitor.setPeekOpen(_:)` does for the now-playing poller.
//

import Foundation
import Observation

// MARK: - Model

nonisolated struct AgentSession: Sendable, Identifiable, Equatable {

    nonisolated enum State: Sendable, Equatable {
        /// Blocked on us right now, or stranded by an `esc`. The only state the
        /// user can act on from here.
        case waiting
        /// The transcript grew recently, so something is happening.
        case running
        /// Neither. Still listed — a session you left an hour ago is exactly
        /// what you came here to find again.
        case idle
    }

    let id: String
    let agent: Agent
    let cwd: String
    var gitBranch: String?
    /// Claude Code's own `permissionMode` from the transcript: "auto",
    /// "acceptEdits", "default" or "plan". Used once, to seed this session's
    /// policy — never shown as a second mode badge competing with the control.
    var observedMode: String?
    var lastActivity: Date
    var state: State = .idle
    /// How many calls this app has answered for the session without asking.
    /// Shown in the row: an auto-answer engine that keeps no visible count is
    /// just the app deciding things quietly.
    var autoAnswered: Int = 0

    /// Same derivation as `Prompt.projectName`, so a session and a prompt from
    /// that session read identically.
    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "unknown" : name
    }

    /// Sort key: something waiting on you first, then whatever is moving, then
    /// the rest by recency.
    var rank: Int {
        switch state {
        case .waiting: return 0
        case .running: return 1
        case .idle: return 2
        }
    }
}

// MARK: - Parsing

/// Pure, filesystem-free parsing. Split out so the whole of it is testable from
/// a string literal — the tails these run on are truncated mid-line in practice,
/// and that case needs a test more than the happy path does.
nonisolated enum AgentSessionScan {

    /// How much of the end of a transcript to read. The interesting fields ride
    /// on nearly every record, so this only has to be big enough to contain a
    /// few whole ones — and small enough that scanning a hundred sessions is a
    /// hundred small reads rather than a hundred whole files. A single Claude
    /// Code record with a large tool result can run past 64 KB on its own; the
    /// parser degrades to "found nothing" in that case rather than misreading.
    static let tailBytes = 64 * 1024

    /// Anything older than this isn't listed at all. A session you have not
    /// touched in a day is not something you are looking for in a notch.
    static let staleAfter: TimeInterval = 24 * 60 * 60

    /// Below this, the transcript is still moving.
    static let runningWithin: TimeInterval = 90

    /// Reads the fields we care about out of the tail of a Claude Code
    /// transcript.
    ///
    /// Walks backwards: the most recent record wins for every field, and the
    /// walk stops as soon as each has been answered. The *first* line is
    /// skipped unless the tail happens to start at a record boundary — a tail
    /// read almost always begins mid-record, and half a JSON object is not a
    /// record.
    ///
    /// Every field is optional on purpose. This format is undocumented and can
    /// change without notice; a session that parses badly should be listed with
    /// what is known, not dropped.
    static func parseClaudeTail(_ text: String, sessionID: String) -> AgentSession? {
        var cwd: String?
        var branch: String?
        var mode: String?
        var timestamp: Date?

        for line in usableLines(text).reversed() {
            guard let object = jsonObject(line) else { continue }

            if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty {
                cwd = value
            }
            if branch == nil, let value = object["gitBranch"] as? String, !value.isEmpty {
                branch = value
            }
            // Rides on `user` records, and only when it isn't the default. The
            // newest one seen is the session's current mode.
            if mode == nil, let value = object["permissionMode"] as? String, !value.isEmpty {
                mode = value
            }
            if timestamp == nil, let value = object["timestamp"] as? String {
                timestamp = Self.date(from: value)
            }
            if cwd != nil, branch != nil, mode != nil, timestamp != nil { break }
        }

        // Without a cwd there is nothing to call the session, and a row reading
        // "unknown" with no branch is worse than no row.
        guard let cwd else { return nil }

        return AgentSession(
            id: sessionID,
            agent: .claudeCode,
            cwd: cwd,
            gitBranch: branch,
            observedMode: mode,
            lastActivity: timestamp ?? .distantPast
        )
    }

    /// The same job for a Codex rollout. Codex writes its identity once, in a
    /// `session_meta` record at the head of the file, so this reads forwards
    /// from the start rather than backwards from the end — and takes the
    /// timestamp from the file's own modification date instead, which the
    /// caller passes in.
    static func parseCodexHead(_ text: String, modifiedAt: Date) -> AgentSession? {
        for line in usableLines(text, skippingFirst: false) {
            guard let object = jsonObject(line),
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let id = payload["session_id"] as? String,
                  let cwd = payload["cwd"] as? String
            else { continue }

            return AgentSession(
                id: id,
                agent: .codex,
                cwd: cwd,
                gitBranch: nil,
                observedMode: nil,
                lastActivity: modifiedAt
            )
        }
        return nil
    }

    // MARK: Helpers

    /// Splits into lines and drops the ones that can't be whole records.
    ///
    /// `skippingFirst` exists because the two callers stand at opposite ends of
    /// a file: a tail read starts mid-record and must drop its first line, a
    /// head read starts at byte zero and must not.
    private static func usableLines(
        _ text: String,
        skippingFirst: Bool = true
    ) -> [Substring] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if skippingFirst, !lines.isEmpty, !text.hasPrefix("{") {
            lines.removeFirst()
        }
        return lines
    }

    private static func jsonObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Claude Code writes fractional seconds; Codex sometimes doesn't. Trying
    /// both is cheaper than being wrong about which.
    ///
    /// Built per call rather than held in a static, matching
    /// `CodexPlanQuestionWatcher.timestamp(from:)`: `ISO8601DateFormatter` is
    /// not `Sendable`, and this runs off the main actor. At a handful of dates
    /// per changed file per scan the allocation is not the cost worth saving.
    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

// MARK: - Scanner

/// File work, off the main actor. Mirrors `CodexPlanQuestionWatcher`: only
/// files whose modification date moved are re-read, so the steady-state cost of
/// an open Agents tab is two directory listings and a `stat` per session.
actor AgentSessionScanner {

    private struct Cached {
        let modifiedAt: Date
        let session: AgentSession?
    }

    private let claudeRoot: URL
    private let codexRoot: URL
    private var cache: [String: Cached] = [:]

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        claudeRoot = homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        codexRoot = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func scan(now: Date = Date()) -> [AgentSession] {
        let manager = FileManager.default
        var found: [AgentSession] = []
        var live: Set<String> = []

        for url in claudeTranscripts(now: now, manager: manager)
            + codexRollouts(now: now, manager: manager) {
            live.insert(url.path)
            guard let modifiedAt = modificationDate(of: url, manager: manager) else { continue }

            if let cached = cache[url.path], cached.modifiedAt == modifiedAt {
                if var session = cached.session {
                    session.state = state(for: session.lastActivity, now: now)
                    found.append(session)
                }
                continue
            }

            let parsed = parse(url: url, modifiedAt: modifiedAt)
            cache[url.path] = Cached(modifiedAt: modifiedAt, session: parsed)
            if var session = parsed {
                session.state = state(for: session.lastActivity, now: now)
                found.append(session)
            }
        }

        for stale in cache.keys where !live.contains(stale) {
            cache.removeValue(forKey: stale)
        }

        // A session id can appear in more than one place — Codex writes one
        // rollout per resume. Newest wins.
        var byID: [String: AgentSession] = [:]
        for session in found {
            if let existing = byID[session.id], existing.lastActivity >= session.lastActivity {
                continue
            }
            byID[session.id] = session
        }
        return Array(byID.values)
    }

    private func state(for lastActivity: Date, now: Date) -> AgentSession.State {
        now.timeIntervalSince(lastActivity) < AgentSessionScan.runningWithin ? .running : .idle
    }

    private func parse(url: URL, modifiedAt: Date) -> AgentSession? {
        if url.path.hasPrefix(claudeRoot.path) {
            guard let text = tail(of: url, bytes: AgentSessionScan.tailBytes) else { return nil }
            return AgentSessionScan.parseClaudeTail(
                text,
                sessionID: url.deletingPathExtension().lastPathComponent
            )
        }
        guard let text = head(of: url, bytes: AgentSessionScan.tailBytes) else { return nil }
        return AgentSessionScan.parseCodexHead(text, modifiedAt: modifiedAt)
    }

    // MARK: Discovery

    private func claudeTranscripts(now: Date, manager: FileManager) -> [URL] {
        guard let projects = try? manager.contentsOfDirectory(
            at: claudeRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = now.addingTimeInterval(-AgentSessionScan.staleAfter)
        var result: [URL] = []
        for project in projects {
            guard let files = try? manager.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let modifiedAt = modificationDate(of: file, manager: manager),
                      modifiedAt > cutoff else { continue }
                result.append(file)
            }
        }
        return result
    }

    /// Today and yesterday, the same window `CodexPlanQuestionWatcher` uses —
    /// and for the same reason: a session left open across midnight should not
    /// vanish at 00:00.
    private func codexRollouts(now: Date, manager: FileManager) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        let cutoff = now.addingTimeInterval(-AgentSessionScan.staleAfter)
        var result: [URL] = []

        for dayOffset in [0, -1] {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let directory = codexRoot
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
            guard let urls = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for file in urls where file.pathExtension == "jsonl" {
                guard let modifiedAt = modificationDate(of: file, manager: manager),
                      modifiedAt > cutoff else { continue }
                result.append(file)
            }
        }
        return result
    }

    private func modificationDate(of url: URL, manager: FileManager) -> Date? {
        guard let attributes = try? manager.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    // MARK: Reading

    /// The last `bytes` of a file. `FileHandle` rather than `Data(contentsOf:)`
    /// — a long session's transcript runs to tens of megabytes, and reading all
    /// of it to look at the end would be the most expensive thing this app does.
    private func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let offset = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        // A tail can land mid-character; the lossy conversion keeps the rest.
        return String(decoding: data, as: UTF8.self)
    }

    private func head(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Store

@MainActor
@Observable
final class AgentSessionStore {

    private(set) var sessions: [AgentSession] = []
    /// True until the first scan lands, so the tab can say "Looking…" rather
    /// than "No sessions" for the half-second before it knows.
    private(set) var hasScanned = false

    @ObservationIgnored private let scanner = AgentSessionScanner()
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var isVisible = false
    /// Session ids that are blocked on us right now, pushed in by `AppModel`
    /// from the coordinator's queue. The store has no business reaching into
    /// the coordinator, the same way the coordinator has none reaching into a
    /// store.
    @ObservationIgnored private var waitingIDs: Set<String> = []
    @ObservationIgnored private var autoAnswers: [String: Int] = [:]

    /// How often to re-scan while the tab is up. Slower than the media poll: a
    /// session list that updates twice a second is not more useful than one
    /// that updates every two, and this one touches the disk.
    private static let pollSeconds: Double = 2

    // MARK: Lifetime

    /// Called on the edge that puts the Agents tab on and off the notch.
    /// Nothing scans while it is off — see the file header.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        poll?.cancel()
        poll = nil
        guard visible else { return }
        refresh()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollSeconds))
                guard !Task.isCancelled, let self else { return }
                refresh()
            }
        }
    }

    /// One scan, off the poll. Called when a hook arrives so a session that has
    /// just blocked appears without waiting out the interval — and so the list
    /// is warm the first time the tab is opened.
    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            let scanned = await scanner.scan()
            apply(scanned)
        }
    }

    /// The ids currently blocked on us. Kept separate from the scan because the
    /// transcript cannot tell us this: a session waiting on a permission hook
    /// has, by definition, written nothing since.
    func setWaiting(_ ids: Set<String>) {
        guard ids != waitingIDs else { return }
        waitingIDs = ids
        applyWaiting()
    }

    /// Bump the count shown in a session's row. Called on every auto-answer, so
    /// a policy that is doing something says so.
    func noteAutoAnswer(sessionID: String) {
        autoAnswers[sessionID, default: 0] += 1
        applyWaiting()
    }

    // MARK: Private

    private func apply(_ scanned: [AgentSession]) {
        sessions = scanned
        hasScanned = true
        applyWaiting()
        PolicyStore.prune(keeping: Set(scanned.map(\.id)))
    }

    /// Overlays what only this app knows — who is blocked, and how much has been
    /// answered for them — onto what the scan found, then sorts.
    private func applyWaiting() {
        for index in sessions.indices {
            let id = sessions[index].id
            if waitingIDs.contains(id) { sessions[index].state = .waiting }
            sessions[index].autoAnswered = autoAnswers[id] ?? 0
        }
        sessions.sort {
            $0.rank != $1.rank ? $0.rank < $1.rank : $0.lastActivity > $1.lastActivity
        }
    }
}
