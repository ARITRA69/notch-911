import Foundation
import Testing
@testable import notch_911

@Suite("Codex plan question watcher")
struct CodexPlanQuestionWatcherTests {
    @Test("Parses all questions, descriptions, and Other support")
    func parsesFullForm() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.sessionMeta,
            fixture.call(arguments: """
            {"questions":[
              {"id":"one","header":"First","question":"First question?","options":[
                {"label":"Alpha","description":"Alpha detail"},{"label":"Beta","description":"Beta detail"}]},
              {"id":"two","header":"Second","question":"Second question?","options":[
                {"label":"Yes","description":"Choose yes"},{"label":"No","description":"Choose no"}]},
              {"id":"three","header":"Third","question":"Third question?","options":[
                {"label":"Left","description":"Go left"},{"label":"Right","description":"Go right"}]}
            ]}
            """)
        ])

        let changes = await CodexPlanQuestionWatcher(homeDirectory: fixture.home).poll()
        #expect(changes.appeared.count == 1)
        let questions = try #require(changes.appeared.first?.questions)
        #expect(questions.count == 3)
        #expect(questions[0].id == "one")
        #expect(questions[0].options[0].detail == "Alpha detail")
        #expect(questions.filter { !$0.allowsOther }.isEmpty)
    }

    @Test("Ignores malformed and already completed calls")
    func ignoresInvalidAndCompleted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.sessionMeta,
            fixture.call(callID: "complete", arguments: fixture.singleQuestion),
            fixture.output(callID: "complete"),
            fixture.call(callID: "malformed", arguments: "{not-json")
        ])

        let changes = await CodexPlanQuestionWatcher(homeDirectory: fixture.home).poll()
        #expect(changes.appeared.isEmpty)
    }

    @Test("Reports resolution after the function output arrives")
    func reportsResolution() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let watcher = CodexPlanQuestionWatcher(homeDirectory: fixture.home)
        try fixture.write([fixture.sessionMeta, fixture.call(arguments: fixture.singleQuestion)])
        let first = await watcher.poll()
        #expect(first.appeared.map(\.callID) == ["call_test"])

        try fixture.write([
            fixture.sessionMeta,
            fixture.call(arguments: fixture.singleQuestion),
            fixture.output(callID: "call_test")
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: fixture.rollout.path
        )
        let second = await watcher.poll()
        #expect(second.resolvedCallIDs == ["call_test"])
    }

    @Test("Does not resurrect an abandoned old call on launch")
    func ignoresStaleCall() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            fixture.sessionMeta,
            fixture.call(arguments: fixture.singleQuestion, timestamp: "2020-01-01T00:00:00.000Z")
        ])
        let changes = await CodexPlanQuestionWatcher(homeDirectory: fixture.home).poll()
        #expect(changes.appeared.isEmpty)
    }
}

private struct Fixture {
    let home: URL
    let rollout: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("notch-911-tests-\(UUID().uuidString)", isDirectory: true)
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

    var singleQuestion: String {
        "{\"questions\":[{\"id\":\"choice\",\"header\":\"Choice\",\"question\":\"Pick one?\",\"options\":[{\"label\":\"A\",\"description\":\"First\"},{\"label\":\"B\",\"description\":\"Second\"}]}]}"
    }

    func call(
        callID: String = "call_test",
        arguments: String,
        timestamp: String = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    ) -> String {
        line(timestamp: timestamp, type: "response_item", payload: [
            "type": "function_call", "name": "request_user_input",
            "arguments": arguments, "call_id": callID
        ])
    }

    func output(callID: String) -> String {
        line(type: "response_item", payload: [
            "type": "function_call_output", "call_id": callID,
            "output": "{\"answers\":{}}"
        ])
    }

    func write(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: rollout, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }

    private func line(
        timestamp: String = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withInternetDateTime, .withFractionalSeconds]),
        type: String,
        payload: [String: Any]
    ) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "timestamp": timestamp, "type": type, "payload": payload
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
