import Foundation
import Testing
@testable import notch_911

@Suite("Codex completion watcher")
struct CodexCompletionWatcherTests {

    @Test("First poll is a baseline and announces nothing")
    func firstPollIsSilent() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.sessionMeta,
            fixture.taskComplete(turnID: "turn_old", message: "Finished before launch")
        ])

        let watcher = CodexCompletionWatcher(homeDirectory: fixture.home)
        #expect(await watcher.poll().isEmpty)
    }

    @Test("Reports a completion that lands after the baseline")
    func reportsNewCompletion() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.remove() }
        try fixture.write([fixture.sessionMeta])

        let watcher = CodexCompletionWatcher(homeDirectory: fixture.home)
        #expect(await watcher.poll().isEmpty)

        try fixture.write([
            fixture.sessionMeta,
            fixture.taskComplete(
                turnID: "turn_new",
                message: "Rewrote the two commits",
                durationMs: 14502
            )
        ], modifiedAt: Date().addingTimeInterval(5))

        let fresh = await watcher.poll()
        #expect(fresh.count == 1)
        let completion = try #require(fresh.first)
        #expect(completion.turnID == "turn_new")
        #expect(completion.lastAgentMessage == "Rewrote the two commits")
        #expect(completion.cwd == "/tmp/project")
        #expect(completion.duration == 14.502)
    }

    @Test("A turn is announced once, however often it is polled")
    func doesNotRepeat() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.remove() }
        try fixture.write([fixture.sessionMeta])

        let watcher = CodexCompletionWatcher(homeDirectory: fixture.home)
        _ = await watcher.poll()

        try fixture.write([
            fixture.sessionMeta,
            fixture.taskComplete(turnID: "turn_once", message: "Done")
        ], modifiedAt: Date().addingTimeInterval(5))

        #expect(await watcher.poll().count == 1)
        // Touched again with the same content: the mtime moves, the turn does not.
        try fixture.write([
            fixture.sessionMeta,
            fixture.taskComplete(turnID: "turn_once", message: "Done")
        ], modifiedAt: Date().addingTimeInterval(10))
        #expect(await watcher.poll().isEmpty)
    }

    @Test("Ignores records that are not task_complete")
    func ignoresOtherRecords() async throws {
        let fixture = try CompletionFixture()
        defer { fixture.remove() }
        try fixture.write([fixture.sessionMeta])

        let watcher = CodexCompletionWatcher(homeDirectory: fixture.home)
        _ = await watcher.poll()

        try fixture.write([
            fixture.sessionMeta,
            fixture.taskStarted(turnID: "turn_running"),
            fixture.line(type: "response_item", payload: ["type": "message", "role": "assistant"]),
            "{not json at all"
        ], modifiedAt: Date().addingTimeInterval(5))

        #expect(await watcher.poll().isEmpty)
    }
}

@Suite("Completion notice")
struct CompletionNoticeTests {

    @Test("Flattens a multi-line closing message to one bounded line")
    func flattensSummary() {
        let notice = CompletionNotice(
            agent: .claudeCode,
            cwd: "/Users/x/Desktop/personal/notch-911",
            summary: "First line.\n\nSecond   line.\tThird."
        )
        #expect(notice.summary == "First line. Second line. Third.")
        #expect(notice.projectName == "notch-911")
    }

    @Test("Truncates a long message rather than letting it size the panel")
    func truncatesSummary() {
        let notice = CompletionNotice(
            agent: .codex,
            cwd: "/tmp/p",
            summary: String(repeating: "word ", count: 200)
        )
        #expect(notice.summary.count == 141)   // 140 + the ellipsis
        #expect(notice.summary.hasSuffix("…"))
    }

    @Test("Renders duration only when there is one to render")
    func formatsDuration() {
        #expect(CompletionNotice(agent: .codex, cwd: "/tmp/p", summary: "", duration: 4.2)
            .durationText == "4s")
        #expect(CompletionNotice(agent: .codex, cwd: "/tmp/p", summary: "", duration: 72)
            .durationText == "1m 12s")
        // Sub-second turns and unknown durations both render as nothing at all,
        // rather than as a misleading "0s".
        #expect(CompletionNotice(agent: .codex, cwd: "/tmp/p", summary: "", duration: 0.4)
            .durationText == nil)
        #expect(CompletionNotice(agent: .claudeCode, cwd: "/tmp/p", summary: "")
            .durationText == nil)
    }
}

@Suite("Completion banner behaviour")
@MainActor
struct CompletionBannerTests {

    private func notice() -> CompletionNotice {
        CompletionNotice(agent: .claudeCode, cwd: "/tmp/project", summary: "Done")
    }

    @Test("Shows the banner without ever taking the keyboard")
    func neverTakesKeyboard() {
        let coordinator = PromptCoordinator()
        coordinator.announce(notice())

        #expect(coordinator.idleSurface == .completion)
        #expect(coordinator.completion != nil)
        // The property that keeps it a notification rather than an
        // interruption. It does accept clicks — that is how you reach the agent
        // that just finished — but a keystroke meant for your editor must never
        // land here.
        #expect(!coordinator.wantsKeyboard)
        #expect(coordinator.isInteractive)
    }

    @Test("Dismissing clears both the surface and the notice")
    func dismissClears() {
        let coordinator = PromptCoordinator()
        coordinator.announce(notice())
        coordinator.dismissCompletion()

        #expect(coordinator.idleSurface == .none)
        #expect(coordinator.completion == nil)
    }

    @Test("Declines to cover a surface the user opened themselves")
    func yieldsToDeliberateSurfaces() {
        let coordinator = PromptCoordinator()
        coordinator.toggleClipboard()
        #expect(coordinator.idleSurface == .clipboard)

        coordinator.announce(notice())
        #expect(coordinator.idleSurface == .clipboard)
        #expect(coordinator.completion == nil)
    }
}

private struct CompletionFixture {
    let home: URL
    let rollout: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-911-completion-\(UUID().uuidString)", isDirectory: true)
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        let directory = home
            .appendingPathComponent(".codex/sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rollout = directory.appendingPathComponent("rollout-test.jsonl")
    }

    var sessionMeta: String {
        line(type: "session_meta", payload: ["id": "session_test", "cwd": "/tmp/project"])
    }

    func taskComplete(turnID: String, message: String, durationMs: Double = 4211) -> String {
        line(type: "event_msg", payload: [
            "type": "task_complete",
            "turn_id": turnID,
            "last_agent_message": message,
            "completed_at": Date().timeIntervalSince1970,
            "duration_ms": durationMs,
        ])
    }

    func taskStarted(turnID: String) -> String {
        line(type: "event_msg", payload: ["type": "task_started", "turn_id": turnID])
    }

    /// `modifiedAt` is set explicitly because the watcher skips any rollout
    /// whose mtime has not moved. Two writes inside the same test can land on
    /// the same timestamp, which would make the second poll a no-op and the
    /// test pass or fail on filesystem timing rather than on behaviour.
    func write(_ lines: [String], modifiedAt: Date? = nil) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rollout, options: .atomic)
        if let modifiedAt {
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: rollout.path
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }

    func line(type: String, payload: [String: Any]) -> String {
        let timestamp = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .gmt,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
        let data = try! JSONSerialization.data(withJSONObject: [
            "timestamp": timestamp, "type": type, "payload": payload,
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
