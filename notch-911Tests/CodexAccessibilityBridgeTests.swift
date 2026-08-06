import ApplicationServices
import Foundation
import Testing
@testable import notch_911

@Suite("Codex Accessibility bridge")
struct CodexAccessibilityBridgeTests {
    @Test("Presses a pressable ancestor for a nested option label, then submits")
    func nestedOptionAndSubmit() throws {
        let controller = FakeAccessibilityController(snapshots: [[
            node(0),
            node(1, parent: 0, role: kAXGroupRole),
            node(2, parent: 1, text: "Which environment should I use?"),
            node(3, parent: 1, role: kAXButtonRole, actions: [kAXPressAction]),
            node(4, parent: 3, text: "Staging"),
            node(5, parent: 1, role: kAXButtonRole, text: "Submit answers", actions: [kAXPressAction]),
        ]])

        try bridge(controller).submit(
            to: 1,
            questions: [question(id: "env", text: "Which environment should I use?", options: ["Staging"])],
            answers: [CodexQuestionAnswer(questionID: "env", selectedLabel: "Staging", otherText: nil)]
        )

        #expect(controller.pressed == [3, 5])
    }

    @Test("Paginated questions use the displayed global shortcut sequence")
    func paginatedShortcutSequence() throws {
        let controller = FakeAccessibilityController(snapshots: [[]])

        try bridge(controller).submit(
            to: 1,
            questions: [
                question(id: "theme", text: "Choose a theme?", options: ["Dark", "Light", "System"]),
                question(id: "spacing", text: "Choose spacing?", options: ["Comfortable", "Compact"]),
                question(id: "destination", text: "Choose destination?", options: ["Downloads", "Desktop"]),
            ],
            answers: [
                CodexQuestionAnswer(questionID: "theme", selectedLabel: "Light", otherText: nil),
                CodexQuestionAnswer(questionID: "spacing", selectedLabel: "Compact", otherText: nil),
                CodexQuestionAnswer(questionID: "destination", selectedLabel: "Downloads", otherText: nil),
            ]
        )

        #expect(controller.postedEvents == [.number(2), .number(5), .number(6)])
        #expect(controller.pressed.isEmpty)
    }

    @Test("Selects Other, fills the revealed field, and submits")
    func otherAnswer() throws {
        let collapsed = [
            node(0),
            node(1, parent: 0, role: kAXGroupRole),
            node(2, parent: 1, text: "What should it be called?"),
            node(3, parent: 1, role: kAXButtonRole, text: "Other", actions: [kAXPressAction]),
            node(6, parent: 1, role: kAXButtonRole, text: "Send", actions: [kAXPressAction]),
        ]
        let expanded = [
            node(0),
            node(1, parent: 0, role: kAXGroupRole),
            node(2, parent: 1, text: "What should it be called?"),
            node(3, parent: 1, role: kAXButtonRole, text: "Other", actions: [kAXPressAction]),
            node(5, parent: 1, role: kAXTextFieldRole),
            node(6, parent: 1, role: kAXButtonRole, text: "Send", actions: [kAXPressAction]),
        ]
        let controller = FakeAccessibilityController(snapshots: [collapsed, expanded])

        try bridge(controller).submit(
            to: 1,
            questions: [question(id: "name", text: "What should it be called?", options: ["Default"])],
            answers: [CodexQuestionAnswer(questionID: "name", selectedLabel: nil, otherText: "Aurora")]
        )

        #expect(controller.pressed == [3, 6])
        #expect(controller.values == [5: "Aurora"])
    }

    @Test("Reports permission and unmatched-control failures")
    func failures() throws {
        let untrusted = FakeAccessibilityController(trusted: false, snapshots: [[]])
        #expect(throws: CodexAccessibilityError.self) {
            try bridge(untrusted).submit(to: 1, questions: [], answers: [])
        }

        let missing = FakeAccessibilityController(snapshots: [[
            node(0),
            node(1, parent: 0, text: "Pick a color?"),
        ]])
        do {
            try bridge(missing).submit(
                to: 1,
                questions: [question(id: "color", text: "Pick a color?", options: ["Blue"])],
                answers: [CodexQuestionAnswer(questionID: "color", selectedLabel: "Blue", otherText: nil)]
            )
            Issue.record("Expected a missing option error")
        } catch CodexAccessibilityError.controlsNotReady(let header) {
            #expect(header == "Question")
        }
        #expect(missing.snapshotCallCount == 4)
    }

    @Test("Retries until both the delayed question and option are mounted")
    func delayedQuestionControls() throws {
        let questionOnly = [
            node(0),
            node(1, parent: 0, role: kAXGroupRole),
            node(2, parent: 1, text: "Choose a region?"),
        ]
        let ready = questionOnly + [
            node(3, parent: 1, role: kAXButtonRole, text: "India", actions: [kAXPressAction]),
        ]
        let controller = FakeAccessibilityController(snapshots: [[], questionOnly, ready, []])

        try bridge(controller).submit(
            to: 1,
            questions: [question(id: "region", text: "Choose a region?", options: ["India"])],
            answers: [CodexQuestionAnswer(questionID: "region", selectedLabel: "India", otherText: nil)]
        )

        #expect(controller.pressed == [3])
        #expect(controller.snapshotCallCount == 4)
    }

    @Test("Paginated Other posts its shortcut, Unicode text, and Return")
    func paginatedOther() throws {
        let controller = FakeAccessibilityController(snapshots: [[]])

        try bridge(controller).submit(
            to: 1,
            questions: [
                question(id: "first", text: "First question?", options: ["One", "Two", "Three"]),
                question(id: "second", text: "Second question?", options: ["Red", "Blue", "Green"]),
                question(id: "third", text: "Third question?", options: ["Small", "Medium", "Large"]),
            ],
            answers: [
                CodexQuestionAnswer(questionID: "first", selectedLabel: "One", otherText: nil),
                CodexQuestionAnswer(questionID: "second", selectedLabel: "Blue", otherText: nil),
                CodexQuestionAnswer(questionID: "third", selectedLabel: nil, otherText: "Café 🔵"),
            ]
        )

        #expect(controller.postedEvents == [
            .number(1), .number(5), .number(10), .text("Café 🔵"), .returnKey,
        ])
    }

    @Test("Cancellation prevents remaining paginated keyboard events")
    func paginatedCancellation() throws {
        let cancellation = CodexSubmissionCancellation()
        let controller = FakeAccessibilityController(snapshots: [[]])
        controller.onNumberPosted = { _ in cancellation.cancel() }

        do {
            try bridge(controller).submit(
                to: 1,
                questions: [
                    question(id: "first", text: "First?", options: ["Yes"]),
                    question(id: "second", text: "Second?", options: ["Yes"]),
                ],
                answers: [
                    CodexQuestionAnswer(questionID: "first", selectedLabel: "Yes", otherText: nil),
                    CodexQuestionAnswer(questionID: "second", selectedLabel: "Yes", otherText: nil),
                ],
                cancellation: cancellation
            )
            Issue.record("Expected cancellation")
        } catch CodexAccessibilityError.cancelled {
            // Expected.
        }

        #expect(controller.postedEvents == [.number(1)])
    }

    @Test("Retries while an Other text field is being revealed")
    func delayedOtherField() throws {
        let collapsed = [
            node(0),
            node(1, parent: 0, role: kAXGroupRole),
            node(2, parent: 1, text: "Name the release?"),
            node(3, parent: 1, role: kAXButtonRole, text: "Other", actions: [kAXPressAction]),
        ]
        let expanded = collapsed + [
            node(4, parent: 1, role: kAXTextAreaRole),
        ]
        let controller = FakeAccessibilityController(snapshots: [collapsed, collapsed, expanded, []])

        try bridge(controller).submit(
            to: 1,
            questions: [question(id: "release", text: "Name the release?", options: ["Default"])],
            answers: [CodexQuestionAnswer(questionID: "release", selectedLabel: nil, otherText: "Aurora")]
        )

        #expect(controller.pressed == [3])
        #expect(controller.values == [4: "Aurora"])
    }

    @Test("Never presses a main-composer Send outside the question container")
    func ignoresGlobalComposer() throws {
        let tree = [
            node(0),
            node(1, parent: 0, role: kAXGroupRole),
            node(2, parent: 1, text: "Choose safely?"),
            node(3, parent: 1, role: kAXButtonRole, text: "Safe", actions: [kAXPressAction]),
            node(4, parent: 0, role: kAXGroupRole),
            node(5, parent: 4, role: kAXButtonRole, text: "Send", actions: [kAXPressAction]),
        ]
        let controller = FakeAccessibilityController(snapshots: [tree])

        try bridge(controller).submit(
            to: 1,
            questions: [question(id: "safe", text: "Choose safely?", options: ["Safe"])],
            answers: [CodexQuestionAnswer(questionID: "safe", selectedLabel: "Safe", otherText: nil)]
        )

        #expect(controller.pressed == [3])
    }

    private func bridge(_ controller: FakeAccessibilityController) -> CodexAccessibilityBridge {
        CodexAccessibilityBridge(
            controller: controller,
            retryPolicy: CodexAccessibilityRetryPolicy(maximumAttempts: 4, interval: 0),
            paginatedTiming: CodexPaginatedSubmissionTiming(
                initialDelay: 0,
                pageDelay: 0,
                otherFieldDelay: 0,
                otherSubmitDelay: 0
            )
        )
    }

    private func question(id: String, text: String, options: [String]) -> CodexQuestion {
        CodexQuestion(
            id: id,
            header: "Question",
            question: text,
            options: options.map { CodexQuestionOption(label: $0, detail: nil) },
            allowsOther: true
        )
    }

    private func node(
        _ id: Int,
        parent: Int? = nil,
        role: String = kAXStaticTextRole,
        text: String = "",
        actions: Set<String> = []
    ) -> CodexAccessibilityNode {
        CodexAccessibilityNode(id: id, parent: parent, role: role, text: text, actions: actions)
    }
}

private final class FakeAccessibilityController: CodexAccessibilityControlling, @unchecked Sendable {
    enum PostedEvent: Equatable {
        case number(Int)
        case text(String)
        case returnKey
    }

    let isTrusted: Bool
    private let snapshots: [[CodexAccessibilityNode]]
    private var snapshotIndex = 0
    private(set) var snapshotCallCount = 0
    private(set) var pressed: [Int] = []
    private(set) var values: [Int: String] = [:]
    private(set) var postedEvents: [PostedEvent] = []
    var onNumberPosted: ((Int) -> Void)?

    init(trusted: Bool = true, snapshots: [[CodexAccessibilityNode]]) {
        isTrusted = trusted
        self.snapshots = snapshots
    }

    func snapshot(processID: pid_t) -> [CodexAccessibilityNode] {
        snapshotCallCount += 1
        guard !snapshots.isEmpty else { return [] }
        let result = snapshots[min(snapshotIndex, snapshots.count - 1)]
        snapshotIndex += 1
        return result
    }

    func press(nodeID: Int) -> Bool {
        pressed.append(nodeID)
        return true
    }

    func setValue(_ value: String, nodeID: Int) -> Bool {
        values[nodeID] = value
        return true
    }

    func postNumberShortcut(_ number: Int, processID: pid_t) -> Bool {
        postedEvents.append(.number(number))
        onNumberPosted?(number)
        return true
    }

    func postText(_ text: String, processID: pid_t) -> Bool {
        postedEvents.append(.text(text))
        return true
    }

    func postReturn(processID: pid_t) -> Bool {
        postedEvents.append(.returnKey)
        return true
    }
}
