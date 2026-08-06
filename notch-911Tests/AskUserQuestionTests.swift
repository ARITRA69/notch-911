import Foundation
import Testing
@testable import notch_911

@Suite("AskUserQuestion parsing and answering")
struct AskUserQuestionTests {

    // MARK: Parsing

    @Test("Parses every question with headers, multiSelect and option details")
    func parsesFullInput() throws {
        let prompt = try #require(Prompt.make(
            agent: .claudeCode,
            event: .permissionRequest,
            body: hookBody(toolInput: """
            {"questions":[
              {"question":"Which areas?","header":"Focus","multiSelect":true,"options":[
                {"label":"UI","description":"Panels and animation"},
                {"label":"Server","description":"Hook handling"}]},
              {"question":"Add tests?","header":"Tests","multiSelect":false,"options":[
                {"label":"Yes"},{"label":"No"}]}
            ]}
            """)
        ))

        guard case .question(let questions) = prompt.kind else {
            Issue.record("expected .question, got \(prompt.kind)")
            return
        }
        #expect(questions.count == 2)
        #expect(prompt.title == "Which areas?")
        #expect(questions[0].header == "Focus")
        #expect(questions[0].multiSelect)
        #expect(questions[0].options.map(\.label) == ["UI", "Server"])
        #expect(questions[0].options[0].detail == "Panels and animation")
        #expect(questions[1].id == 1)
        #expect(!questions[1].multiSelect)
        #expect(questions[1].options[1].detail == nil)
    }

    @Test("Missing header, multiSelect, options and duplicate labels all degrade")
    func degradesPerQuestion() throws {
        let questions = try #require(AskUserQuestionInput.parse(toolInput("""
        {"questions":[
          {"question":"No options here?"},
          {"question":"Duplicates?","options":[{"label":"Same"},{"label":"Same"},{"label":"Other one"}]},
          {"question":""}
        ]}
        """)))

        #expect(questions.count == 2)
        #expect(questions[0].header == "")
        #expect(!questions[0].multiSelect)
        #expect(questions[0].options.isEmpty)
        #expect(questions[1].options.map(\.label) == ["Same", "Other one"])
    }

    @Test("A call with no readable question falls back to the permission card")
    func fallsBackWhenUnparseable() throws {
        let prompt = try #require(Prompt.make(
            agent: .claudeCode,
            event: .permissionRequest,
            body: hookBody(toolInput: #"{"questions":[]}"#)
        ))
        guard case .permission = prompt.kind else {
            Issue.record("expected .permission fallback, got \(prompt.kind)")
            return
        }
        #expect(prompt.title == "AskUserQuestion")
    }

    @Test("Other tools keep the plain permission card")
    func otherToolsUnaffected() throws {
        let body = Data("""
        {"session_id":"s","cwd":"/tmp/p","tool_name":"Bash","tool_input":{"command":"ls"}}
        """.utf8)
        let prompt = try #require(Prompt.make(agent: .claudeCode, event: .permissionRequest, body: body))
        guard case .permission = prompt.kind else {
            Issue.record("expected .permission, got \(prompt.kind)")
            return
        }
        #expect(prompt.summary == "ls")
    }

    // MARK: Response wire format

    @Test("Answers serialise as deny with the selections in the message")
    func answersBecomeDenyMessage() throws {
        let question = AskQuestion(
            id: 0, header: "Focus", question: "Which areas?", multiSelect: true,
            options: [AskOption(label: "UI", detail: nil), AskOption(label: "Server", detail: nil)]
        )
        let response = PromptResponse.answers([
            AskAnswer(question: question, selectedLabels: ["UI", "Server"], otherText: "the shelf")
        ])

        let decision = try decision(of: response)
        #expect(decision["behavior"] as? String == "deny")
        let message = try #require(decision["message"] as? String)
        #expect(message.contains("Q: Which areas?"))
        #expect(message.contains("A: UI, Server, the shelf"))
        #expect(message.contains("do not re-ask"))
        #expect(decision["interrupt"] == nil)
    }

    @Test("Each question gets its own Q/A pair in the message")
    func multiQuestionMessage() throws {
        let first = AskQuestion(id: 0, header: "", question: "First?", multiSelect: false,
                                options: [AskOption(label: "A", detail: nil)])
        let second = AskQuestion(id: 1, header: "", question: "Second?", multiSelect: false, options: [])
        let message = AskAnswer.denyMessage([
            AskAnswer(question: first, selectedLabels: ["A"], otherText: nil),
            AskAnswer(question: second, selectedLabels: [], otherText: "typed answer"),
        ])
        #expect(message.contains("Q: First?\nA: A"))
        #expect(message.contains("Q: Second?\nA: typed answer"))
    }

    @Test("Allowing still sends the minimal decision with no message key")
    func allowStaysMinimal() throws {
        let decision = try decision(of: .permission(.allow))
        #expect(decision["behavior"] as? String == "allow")
        #expect(decision["message"] == nil)
    }

    // MARK: Fixtures

    private func hookBody(toolInput: String) -> Data {
        Data("""
        {"session_id":"s","cwd":"/tmp/p","hook_event_name":"PermissionRequest",
         "tool_name":"AskUserQuestion","tool_input":\(toolInput)}
        """.utf8)
    }

    private func toolInput(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func decision(of response: PromptResponse) throws -> [String: Any] {
        let body = try #require(response.body(for: .permissionRequest))
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let output = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        return try #require(output["decision"] as? [String: Any])
    }
}
