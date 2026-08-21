import Foundation
import Testing
@testable import notch_911

// MARK: - Rollout detection

@Suite("Codex approval watcher · rollout detection")
struct CodexApprovalRolloutTests {

    @Test("A dangling escalated call is a pending approval with its question")
    func detectsPending() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.sessionMeta,
            fixture.taskStarted,
            fixture.escalatedCall(callID: "call_1", justification: "May I run a date check?"),
        ])

        let watcher = CodexApprovalWatcher(homeDirectory: fixture.home, reader: FakeReader(), processID: { nil })
        let changes = await watcher.poll()
        #expect(changes.appeared.count == 1)
        #expect(changes.appeared.first?.callID == "call_1")
        #expect(changes.appeared.first?.question == "May I run a date check?")
        #expect(changes.appeared.first?.cwd == "/tmp/project")
    }

    @Test("An answered call is not pending, and resolves a delivered card")
    func resolvesOnOutput() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.sessionMeta,
            fixture.taskStarted,
            fixture.escalatedCall(callID: "call_1", justification: "May I run a date check?"),
        ])

        let watcher = CodexApprovalWatcher(homeDirectory: fixture.home, reader: FakeReader(), processID: { nil })
        _ = await watcher.poll()

        try fixture.write([
            fixture.sessionMeta,
            fixture.taskStarted,
            fixture.escalatedCall(callID: "call_1", justification: "May I run a date check?"),
            fixture.output(callID: "call_1"),
        ], modifiedAt: Date().addingTimeInterval(5))

        let changes = await watcher.poll()
        #expect(changes.resolvedIDs == ["call_1"])
        #expect(changes.appeared.isEmpty)
    }

    @Test("A turn boundary after the call retires it — interrupted turns don't linger")
    func boundaryRetires() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.sessionMeta,
            fixture.taskStarted,
            fixture.escalatedCall(callID: "call_1", justification: "May I run a date check?"),
            fixture.userMessage("never mind, do something else"),
        ])

        let watcher = CodexApprovalWatcher(homeDirectory: fixture.home, reader: FakeReader(), processID: { nil })
        #expect(await watcher.poll().appeared.isEmpty)
    }

    @Test("Ordinary tool calls without escalation are not approvals")
    func ignoresPlainCalls() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.sessionMeta,
            fixture.taskStarted,
            fixture.call(callID: "call_1", input: #"const r = await tools.exec_command({cmd: "ls"});"#),
        ])
        let watcher = CodexApprovalWatcher(homeDirectory: fixture.home, reader: FakeReader(), processID: { nil })
        #expect(await watcher.poll().appeared.isEmpty)
    }

    @Test("A request_permissions grant is an approval, with its reason as the question")
    func detectsPermissionGrant() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        // Shape taken verbatim from a real rollout on 2026-08-21.
        let input = #"const r = await tools.request_permissions({ permissions: "#
            + #"{ file_system: { write: ["/tmp/x.txt"] } }, "#
            + #"reason: "Allow me to create a harmless test file." }); text(r);"#
        try fixture.write([
            fixture.sessionMeta,
            fixture.taskStarted,
            fixture.call(callID: "call_grant", input: input),
        ])
        let watcher = CodexApprovalWatcher(homeDirectory: fixture.home, reader: FakeReader(), processID: { nil })
        let changes = await watcher.poll()
        #expect(changes.appeared.count == 1)
        #expect(changes.appeared.first?.question == "Allow me to create a harmless test file.")
    }

    @Test("Justification extraction handles JS, JSON and escaped quotes")
    func justificationParsing() {
        #expect(CodexApprovalWatcher.justification(
            in: #"sandbox_permissions: "require_escalated", justification: "May I?","#
        ) == "May I?")
        #expect(CodexApprovalWatcher.justification(
            in: #"{"with_escalated_permissions":true,"justification":"Delete \"old\" file?"}"#
        ) == #"Delete "old" file?"#)
        #expect(CodexApprovalWatcher.justification(in: "no justification here") == nil)
    }
}

// MARK: - Pressing

private final class FakeReader: CodexApprovalTreeReading, @unchecked Sendable {
    var nodes: [CodexAccessibilityNode]? = []
    var pressed: [Int] = []
    var isTrusted: Bool { true }
    func windowNodes(processID: pid_t) -> [CodexAccessibilityNode]? { nodes }
    func press(nodeID: Int) -> Bool { pressed.append(nodeID); return true }
}

private func approvalTree(question: String = "May I run a date check?") -> [CodexAccessibilityNode] {
    [
        .init(id: 0, parent: nil, role: "AXWindow", text: "Codex", actions: []),
        .init(id: 1, parent: 0, role: "AXGroup", text: "", actions: []),
        .init(id: 2, parent: 1, role: "AXStaticText", text: question, actions: []),
        .init(id: 3, parent: 1, role: "AXGroup", text: "", actions: []),
        .init(id: 4, parent: 3, role: "AXButton", text: "Deny", actions: []),
        .init(id: 5, parent: 3, role: "AXButton", text: "Allow once", actions: []),
    ]
}

@Suite("Codex approval watcher · pressing")
struct CodexApprovalPressTests {

    @Test("Finds the on-screen cluster with question and both labels")
    func findsCluster() {
        let clusters = CodexApprovalWatcher.approvals(in: approvalTree())
        #expect(clusters.count == 1)
        #expect(clusters.first?.question == "May I run a date check?")
        #expect(clusters.first?.allowLabel == "Allow once")
        #expect(clusters.first?.denyLabel == "Deny")
    }

    @Test("Allow presses the allow button, deny presses deny")
    func pressesCorrectButton() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let reader = FakeReader()
        reader.nodes = approvalTree()
        let watcher = CodexApprovalWatcher(homeDirectory: fixture.home, reader: reader, processID: { 42 })

        #expect(await watcher.press(question: "May I run a date check?", allow: true))
        #expect(reader.pressed == [5])
        #expect(await watcher.press(question: "May I run a date check?", allow: false))
        #expect(reader.pressed == [5, 4])
    }

    @Test("A lone on-screen approval is pressed even when its text was re-wrapped")
    func lonePromptMatchesLoosely() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let reader = FakeReader()
        reader.nodes = approvalTree(question: "May I run a date check? Some extra UI text")
        let watcher = CodexApprovalWatcher(homeDirectory: fixture.home, reader: reader, processID: { 42 })

        #expect(await watcher.press(question: "May I run a date check?", allow: true))
        #expect(reader.pressed == [5])
    }

    @Test("Press fails cleanly when the window is on another Space")
    func pressFailsOffSpace() async throws {
        let fixture = try ApprovalFixture()
        defer { fixture.remove() }
        let reader = FakeReader()
        reader.nodes = nil
        let watcher = CodexApprovalWatcher(homeDirectory: fixture.home, reader: reader, processID: { 42 })

        #expect(await watcher.press(question: "Anything", allow: true) == false)
        #expect(reader.pressed.isEmpty)
    }
}

// MARK: - Fixture

private struct ApprovalFixture {
    let home: URL
    let rollout: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-911-approval-\(UUID().uuidString)", isDirectory: true)
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

    var taskStarted: String {
        line(type: "event_msg", payload: ["type": "task_started", "turn_id": "turn_1"])
    }

    func userMessage(_ text: String) -> String {
        line(type: "event_msg", payload: ["type": "user_message", "message": text])
    }

    func escalatedCall(callID: String, justification: String) -> String {
        call(callID: callID, input: """
        const r = await tools.exec_command({ cmd: "date", \
        sandbox_permissions: "require_escalated", justification: "\(justification)" });
        """)
    }

    func call(callID: String, input: String) -> String {
        line(type: "response_item", payload: [
            "type": "custom_tool_call", "name": "exec",
            "call_id": callID, "input": input, "status": "completed",
        ])
    }

    func output(callID: String) -> String {
        line(type: "response_item", payload: [
            "type": "custom_tool_call_output", "call_id": callID, "output": "done",
        ])
    }

    func write(_ lines: [String], modifiedAt: Date? = nil) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rollout, options: .atomic)
        if let modifiedAt {
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt], ofItemAtPath: rollout.path
            )
        }
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    private func line(type: String, payload: [String: Any]) -> String {
        let timestamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .gmt,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
        let data = try! JSONSerialization.data(withJSONObject: [
            "timestamp": timestamp, "type": type, "payload": payload,
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
