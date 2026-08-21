import Foundation
import Testing
@testable import notch_911

@Suite("Plan mode prompts")
struct PlanPromptTests {

    // MARK: Parsing

    @Test("ExitPlanMode becomes a plan prompt carrying the markdown and the file")
    func makesPlanPrompt() throws {
        let prompt = try #require(Prompt.make(
            agent: .claudeCode,
            event: .permissionRequest,
            body: body(toolName: "ExitPlanMode", toolInput: """
            {"plan":"## Steps\\n- Do the thing","planFilePath":"/tmp/plans/thing.md"}
            """)
        ))

        guard case .plan(let markdown, let filePath) = prompt.kind else {
            Issue.record("expected .plan, got \(prompt.kind)")
            return
        }
        #expect(markdown == "## Steps\n- Do the thing")
        #expect(filePath == "/tmp/plans/thing.md")
        #expect(prompt.toolName == "ExitPlanMode")
        // The plan itself is the prompt, so the title is the question rather
        // than the tool's name.
        #expect(prompt.title == "Ready to code?")
    }

    @Test("A plan with no file path still parses")
    func planWithoutFilePath() throws {
        let prompt = try #require(Prompt.make(
            agent: .claudeCode,
            event: .permissionRequest,
            body: body(toolName: "ExitPlanMode", toolInput: #"{"plan":"Just do it"}"#)
        ))
        guard case .plan(_, let filePath) = prompt.kind else {
            Issue.record("expected .plan, got \(prompt.kind)")
            return
        }
        #expect(filePath == nil)
    }

    /// A session blocked forever is worse than a vague card, so anything we
    /// can't read as a plan degrades to the generic allow/deny rather than
    /// failing to build a prompt at all.
    @Test("An ExitPlanMode with no usable plan degrades to a permission card",
          arguments: [#"{}"#, #"{"plan":""}"#, #"{"plan":"   "}"#, #"{"plan":123}"#])
    func degradesWithoutAPlan(_ input: String) throws {
        let prompt = try #require(Prompt.make(
            agent: .claudeCode,
            event: .permissionRequest,
            body: body(toolName: "ExitPlanMode", toolInput: input)
        ))
        guard case .permission = prompt.kind else {
            Issue.record("expected .permission, got \(prompt.kind)")
            return
        }
        #expect(prompt.title == "ExitPlanMode")
    }

    @Test("The keyboard map treats a plan as having text entry")
    func planHasTextEntry() throws {
        let prompt = try #require(Prompt.make(
            agent: .claudeCode,
            event: .permissionRequest,
            body: body(toolName: "ExitPlanMode", toolInput: #"{"plan":"x"}"#)
        ))
        #expect(prompt.kind.hasTextEntry)
    }

    // MARK: Answering

    @Test("Approving a plan is an ordinary allow, whichever mode it approves into",
          arguments: [PermissionPolicy.acceptEdits, .manual])
    func approveIsAnAllow(_ policy: PermissionPolicy) throws {
        let decision = try decision(of: .plan(.approve(policy: policy)))
        #expect(decision["behavior"] as? String == "allow")
        // The mode is this app's business and never reaches the wire.
        #expect(decision["message"] == nil)
    }

    @Test("Keeping planning is a deny that tells the model not to start")
    func keepPlanningIsADeny() throws {
        let decision = try decision(of: .plan(.keepPlanning(feedback: "")))
        #expect(decision["behavior"] as? String == "deny")
        let message = try #require(decision["message"] as? String)
        #expect(message.contains("Do not start implementing"))
        #expect(message.contains("Revise the plan"))
    }

    @Test("Feedback rides the deny message so the model can revise")
    func feedbackRidesTheDenyMessage() throws {
        let decision = try decision(of: .plan(.keepPlanning(feedback: "Use the existing parser")))
        #expect(decision["behavior"] as? String == "deny")
        let message = try #require(decision["message"] as? String)
        #expect(message.contains("Use the existing parser"))
        #expect(message.contains("revise the plan"))
    }

    @Test("Whitespace-only feedback is treated as none")
    func blankFeedback() throws {
        let decision = try decision(of: .plan(.keepPlanning(feedback: "   \n  ")))
        let message = try #require(decision["message"] as? String)
        #expect(message.contains("Revise the plan and present it again"))
    }

    /// A plan answer only means anything on the hook that asked it.
    @Test("A plan response on a non-permission event is no decision")
    func wrongEventYieldsNothing() {
        #expect(PromptResponse.plan(.approve(policy: .manual)).body(for: .stop) == nil)
        #expect(PromptResponse.plan(.keepPlanning(feedback: "x")).body(for: .elicitation) == nil)
    }

    // MARK: The side effect

    /// The "Auto-accept edits" button makes a promise beyond its answer — that
    /// the session will stop asking about edits — and the promise is kept here,
    /// not in the card. Pinned because resolving and applying the mode are two
    /// separate things, and the answer worked fine while the mode quietly did
    /// nothing.
    @MainActor
    @Test("Approving a plan applies the mode it was approved into")
    func approvalAppliesThePolicy() async {
        let coordinator = PromptCoordinator()
        var applied: [String: PermissionPolicy] = [:]
        coordinator.onPolicyChange = { applied[$0] = $1 }

        let prompt = planPrompt(sessionId: "sess-1")
        let task = Task { await coordinator.response(to: prompt) }
        while coordinator.current?.id != prompt.id { await Task.yield() }

        coordinator.resolve(prompt, with: .plan(.approve(policy: .acceptEdits)))
        _ = await task.value

        #expect(applied["sess-1"] == .acceptEdits)
        #expect(coordinator.policy(for: "sess-1") == .acceptEdits)
    }

    @MainActor
    @Test("Keeping planning changes no mode")
    func keepPlanningLeavesThePolicyAlone() async {
        let coordinator = PromptCoordinator()
        var applied: [String: PermissionPolicy] = [:]
        coordinator.onPolicyChange = { applied[$0] = $1 }

        let prompt = planPrompt(sessionId: "sess-2")
        let task = Task { await coordinator.response(to: prompt) }
        while coordinator.current?.id != prompt.id { await Task.yield() }

        coordinator.resolve(prompt, with: .plan(.keepPlanning(feedback: "no")))
        _ = await task.value

        #expect(applied.isEmpty)
        #expect(coordinator.policy(for: "sess-2") == .manual)
    }

    private func planPrompt(sessionId: String) -> Prompt {
        Prompt(
            agent: .claudeCode,
            event: .permissionRequest,
            sessionId: sessionId,
            cwd: "/tmp/p",
            title: "Ready to code?",
            toolName: "ExitPlanMode",
            summary: "",
            kind: .plan(markdown: "- do it", filePath: nil),
            receivedAt: Date()
        )
    }

    // MARK: Markdown

    @Test("The plan renderer picks apart headings, bullets, code and rules")
    func rendersPlanBlocks() {
        let blocks = PlanMarkdown.blocks("""
        # Title

        Some prose.

        ## Steps
        - First
        - Second
          - Nested
        1. Numbered

        ```swift
        let x = 1
        ```

        ---
        """)

        #expect(blocks.contains(.heading("Title", level: 1)))
        #expect(blocks.contains(.heading("Steps", level: 2)))
        #expect(blocks.contains(.paragraph("Some prose.")))
        #expect(blocks.contains(.bullet("First", depth: 0)))
        #expect(blocks.contains(.bullet("Nested", depth: 1)))
        #expect(blocks.contains(.bullet("1. Numbered", depth: 0)))
        #expect(blocks.contains(.code("let x = 1")))
        #expect(blocks.contains(.rule))
    }

    /// A plan cut off mid-block is exactly when you want to see what it said.
    @Test("An unterminated code fence still renders")
    func unterminatedFence() {
        let blocks = PlanMarkdown.blocks("""
        ```
        half a thing
        """)
        #expect(blocks == [.code("half a thing")])
    }

    @Test("An empty plan renders nothing rather than trapping")
    func emptyPlan() {
        #expect(PlanMarkdown.blocks("").isEmpty)
        #expect(PlanMarkdown.blocks("\n\n  \n").isEmpty)
    }

    // MARK: Helpers

    private func body(toolName: String, toolInput: String) -> Data {
        Data("""
        {"session_id":"s","cwd":"/tmp/p","hook_event_name":"PermissionRequest",
         "tool_name":"\(toolName)","tool_input":\(toolInput)}
        """.utf8)
    }

    private func decision(of response: PromptResponse) throws -> [String: Any] {
        let body = try #require(response.body(for: .permissionRequest))
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let output = try #require(root["hookSpecificOutput"] as? [String: Any])
        #expect(output["hookEventName"] as? String == "PermissionRequest")
        return try #require(output["decision"] as? [String: Any])
    }
}
