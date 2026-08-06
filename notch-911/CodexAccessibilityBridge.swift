//
//  CodexAccessibilityBridge.swift
//  notch-911
//
//  Codex owns the App Server request/response channel. This bridge answers the
//  already-visible question through semantic macOS Accessibility controls or
//  Codex's paginated shortcuts; it never writes rollouts or fabricates output.
//

import ApplicationServices
import Foundation

nonisolated protocol CodexQuestionSubmitting: Sendable {
    func submit(
        to processID: pid_t,
        questions: [CodexQuestion],
        answers: [CodexQuestionAnswer],
        cancellation: CodexSubmissionCancellation
    ) throws
}

nonisolated final class CodexSubmissionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// A semantic, process-independent view of one Accessibility element. Parent
/// values are indexes into the snapshot, while `id` identifies the underlying
/// AX element for actions.
nonisolated struct CodexAccessibilityNode: Sendable {
    let id: Int
    let parent: Int?
    let role: String
    let text: String
    let actions: Set<String>
}

/// Keeps raw Core Accessibility calls out of matching and submission logic.
/// Tests can provide deterministic trees without controlling a real app.
nonisolated protocol CodexAccessibilityControlling: Sendable {
    var isTrusted: Bool { get }
    func snapshot(processID: pid_t) -> [CodexAccessibilityNode]
    func press(nodeID: Int) -> Bool
    func setValue(_ value: String, nodeID: Int) -> Bool
    func postNumberShortcut(_ number: Int, processID: pid_t) -> Bool
    func postText(_ text: String, processID: pid_t) -> Bool
    func postReturn(processID: pid_t) -> Bool
}

nonisolated struct CodexAccessibilityRetryPolicy: Sendable {
    let maximumAttempts: Int
    let interval: TimeInterval

    /// One immediate attempt plus thirty 100ms retries: controls get up to
    /// three seconds to mount without adding latency when they are already up.
    static let live = CodexAccessibilityRetryPolicy(maximumAttempts: 31, interval: 0.1)
}

nonisolated struct CodexPaginatedSubmissionTiming: Sendable {
    let initialDelay: TimeInterval
    let pageDelay: TimeInterval
    let otherFieldDelay: TimeInterval
    let otherSubmitDelay: TimeInterval

    static let live = CodexPaginatedSubmissionTiming(
        initialDelay: 0.25,
        pageDelay: 0.4,
        otherFieldDelay: 0.15,
        otherSubmitDelay: 0.1
    )
}

nonisolated enum CodexAccessibilityError: Error, LocalizedError, Sendable {
    case permissionRequired
    case controlsNotReady(String)
    case actionFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Enable Accessibility access to answer from the notch."
        case .controlsNotReady:
            return "Codex’s question controls did not become ready."
        case .actionFailed(let label):
            return "Codex did not accept the “\(label)” action."
        case .cancelled:
            return "The Codex question was cancelled."
        }
    }
}

/// Owns the real AX elements behind semantic node IDs. The map is replaced on
/// every snapshot so stale controls cannot accidentally be acted upon.
nonisolated final class SystemCodexAccessibilityController: CodexAccessibilityControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Int: AXUIElement] = [:]

    var isTrusted: Bool { AXIsProcessTrusted() }

    func snapshot(processID: pid_t) -> [CodexAccessibilityNode] {
        let root = AXUIElementCreateApplication(processID)
        var result: [CodexAccessibilityNode] = []
        var captured: [Int: AXUIElement] = [:]
        var queue: [(AXUIElement, Int?, Int)] = [(root, nil, 0)]
        var cursor = 0

        while cursor < queue.count, result.count < 5_000 {
            let (element, parent, depth) = queue[cursor]
            cursor += 1
            // Current Codex question sheets reach depth 30 and their option
            // controls can sit below that. Leave headroom for minor DOM shifts.
            guard depth <= 48 else { continue }

            let nodeIndex = result.count
            let id = Int(CFHash(element))
            captured[id] = element
            result.append(CodexAccessibilityNode(
                id: id,
                parent: parent,
                role: stringValue(element, attribute: kAXRoleAttribute),
                text: accessibleText(element),
                actions: actionNames(element)
            ))
            for child in children(element) {
                queue.append((child, nodeIndex, depth + 1))
            }
        }

        lock.lock()
        elements = captured
        lock.unlock()
        return result
    }

    func press(nodeID: Int) -> Bool {
        guard let element = element(for: nodeID) else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    func setValue(_ value: String, nodeID: Int) -> Bool {
        guard let element = element(for: nodeID) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        ) == .success
    }

    func postNumberShortcut(_ number: Int, processID: pid_t) -> Bool {
        let keyCodes: [Int: CGKeyCode] = [
            1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
            6: 22, 7: 26, 8: 28, 9: 25, 10: 29,
        ]
        guard let keyCode = keyCodes[number] else { return false }
        return postKey(keyCode, flags: .maskCommand, processID: processID)
    }

    func postText(_ text: String, processID: pid_t) -> Bool {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return false }
        var offset = 0
        while offset < units.count {
            let end = min(offset + 20, units.count)
            let chunk = Array(units[offset..<end])
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else { return false }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
                up.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            down.postToPid(processID)
            up.postToPid(processID)
            offset = end
        }
        return true
    }

    func postReturn(processID: pid_t) -> Bool {
        postKey(36, processID: processID)
    }

    private func postKey(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        processID: pid_t
    ) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(processID)
        up.postToPid(processID)
        return true
    }

    private func element(for id: Int) -> AXUIElement? {
        lock.lock()
        defer { lock.unlock() }
        return elements[id]
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let value
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func stringValue(_ element: AXUIElement, attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else { return "" }
        return value as? String ?? ""
    }

    private func accessibleText(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .map { stringValue(element, attribute: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func actionNames(_ element: AXUIElement) -> Set<String> {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let names = value as? [String]
        else { return [] }
        return Set(names)
    }
}

/// Stateless submission logic. The injected controller is the only component
/// that touches real Accessibility elements.
nonisolated final class CodexAccessibilityBridge: CodexQuestionSubmitting, @unchecked Sendable {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private let controller: any CodexAccessibilityControlling
    private let retryPolicy: CodexAccessibilityRetryPolicy
    private let paginatedTiming: CodexPaginatedSubmissionTiming

    init(
        controller: any CodexAccessibilityControlling = SystemCodexAccessibilityController(),
        retryPolicy: CodexAccessibilityRetryPolicy = .live,
        paginatedTiming: CodexPaginatedSubmissionTiming = .live
    ) {
        self.controller = controller
        self.retryPolicy = retryPolicy
        self.paginatedTiming = paginatedTiming
    }

    func submit(
        to processID: pid_t,
        questions: [CodexQuestion],
        answers: [CodexQuestionAnswer],
        cancellation: CodexSubmissionCancellation = CodexSubmissionCancellation()
    ) throws {
        guard controller.isTrusted else { throw CodexAccessibilityError.permissionRequired }
        let answerByID = Dictionary(uniqueKeysWithValues: answers.map { ($0.questionID, $0) })
        if questions.count > 1 {
            try submitPaginated(
                to: processID,
                questions: questions,
                answerByID: answerByID,
                cancellation: cancellation
            )
            return
        }

        var pressedOptionIDs: Set<Int> = []
        var finalContext: (question: CodexQuestion, selectedLabel: String)?

        for question in questions {
            try checkCancellation(cancellation)
            guard let answer = answerByID[question.id] else {
                throw CodexAccessibilityError.actionFailed(question.header)
            }

            if let label = answer.selectedLabel {
                let match = try waitForAction(
                    label,
                    for: question,
                    processID: processID,
                    cancellation: cancellation
                )
                try press(match.nodes[match.actionIndex].id, label: label)
                pressedOptionIDs.insert(match.nodes[match.actionIndex].id)
                finalContext = (question, label)
            } else if let text = answer.otherText {
                let other = try waitForAction(
                    "Other",
                    for: question,
                    processID: processID,
                    cancellation: cancellation
                )
                try press(other.nodes[other.actionIndex].id, label: "Other")
                pressedOptionIDs.insert(other.nodes[other.actionIndex].id)

                let field = try waitForEditableField(
                    for: question,
                    processID: processID,
                    cancellation: cancellation
                )
                guard controller.setValue(text, nodeID: field.nodes[field.fieldIndex].id) else {
                    throw CodexAccessibilityError.actionFailed("Other")
                }
                finalContext = (question, "Other")
            }
        }

        if let finalContext {
            try pressScopedSubmitIfPresent(
                for: finalContext.question,
                selectedLabel: finalContext.selectedLabel,
                excluding: pressedOptionIDs,
                processID: processID,
                cancellation: cancellation
            )
        }
    }

    /// Codex renders multi-question requests one page at a time and currently
    /// omits those pages from its AX child tree. Its visible numeric shortcuts
    /// are stable and can be posted directly to the process without activation.
    private func submitPaginated(
        to processID: pid_t,
        questions: [CodexQuestion],
        answerByID: [String: CodexQuestionAnswer],
        cancellation: CodexSubmissionCancellation
    ) throws {
        try cancellablePause(paginatedTiming.initialDelay, cancellation: cancellation)
        var shortcutOffset = 0
        for question in questions {
            try checkCancellation(cancellation)
            guard let answer = answerByID[question.id] else {
                throw CodexAccessibilityError.actionFailed(question.header)
            }

            let shortcut: Int
            if let label = answer.selectedLabel,
               let index = question.options.firstIndex(where: { $0.label == label }) {
                shortcut = shortcutOffset + index + 1
            } else if answer.otherText != nil, question.allowsOther {
                shortcut = shortcutOffset + question.options.count + 1
            } else {
                throw CodexAccessibilityError.actionFailed(question.header)
            }
            guard shortcut <= 10,
                  controller.postNumberShortcut(shortcut, processID: processID)
            else { throw CodexAccessibilityError.actionFailed("Option \(shortcut)") }

            if let otherText = answer.otherText {
                try cancellablePause(paginatedTiming.otherFieldDelay, cancellation: cancellation)
                try checkCancellation(cancellation)
                guard controller.postText(otherText, processID: processID) else {
                    throw CodexAccessibilityError.actionFailed("Other")
                }
                try cancellablePause(paginatedTiming.otherSubmitDelay, cancellation: cancellation)
                try checkCancellation(cancellation)
                guard controller.postReturn(processID: processID) else {
                    throw CodexAccessibilityError.actionFailed("Other")
                }
            }
            shortcutOffset += question.options.count
            try cancellablePause(paginatedTiming.pageDelay, cancellation: cancellation)
        }
    }

    private struct ActionMatch {
        let nodes: [CodexAccessibilityNode]
        let questionIndex: Int
        let actionIndex: Int
    }

    private struct EditableMatch {
        let nodes: [CodexAccessibilityNode]
        let fieldIndex: Int
    }

    /// Codex mounts its question sheet after the rollout record appears. Wait
    /// for the question and its requested control as one atomic match so a
    /// half-mounted form cannot fail immediately.
    private func waitForAction(
        _ label: String,
        for question: CodexQuestion,
        processID: pid_t,
        cancellation: CodexSubmissionCancellation
    ) throws -> ActionMatch {
        for attempt in 0..<max(1, retryPolicy.maximumAttempts) {
            try checkCancellation(cancellation)
            let nodes = controller.snapshot(processID: processID)
            if let questionIndex = bestTextMatch(question.question, in: nodes),
               let actionIndex = bestActionMatch(label, near: questionIndex, in: nodes) {
                return ActionMatch(nodes: nodes, questionIndex: questionIndex, actionIndex: actionIndex)
            }
            try pause(after: attempt, cancellation: cancellation)
        }
        throw CodexAccessibilityError.controlsNotReady(question.header)
    }

    private func waitForEditableField(
        for question: CodexQuestion,
        processID: pid_t,
        cancellation: CodexSubmissionCancellation
    ) throws -> EditableMatch {
        for attempt in 0..<max(1, retryPolicy.maximumAttempts) {
            try checkCancellation(cancellation)
            let nodes = controller.snapshot(processID: processID)
            if let questionIndex = bestTextMatch(question.question, in: nodes),
               let fieldIndex = nearestEditable(near: questionIndex, in: nodes) {
                return EditableMatch(nodes: nodes, fieldIndex: fieldIndex)
            }
            try pause(after: attempt, cancellation: cancellation)
        }
        throw CodexAccessibilityError.controlsNotReady(question.header)
    }

    /// Option rows submit immediately in the current single-question client.
    /// If Codex instead reveals a separate submit control, it is safe to press
    /// only when it is inside the same semantic container as the question and
    /// selected option. The main composer is deliberately out of scope.
    private func pressScopedSubmitIfPresent(
        for question: CodexQuestion,
        selectedLabel: String,
        excluding pressedOptionIDs: Set<Int>,
        processID: pid_t,
        cancellation: CodexSubmissionCancellation
    ) throws {
        for attempt in 0..<max(1, retryPolicy.maximumAttempts) {
            try checkCancellation(cancellation)
            let nodes = controller.snapshot(processID: processID)
            guard let questionIndex = bestTextMatch(question.question, in: nodes) else {
                return // The option row already submitted or advanced the form.
            }
            if let optionIndex = bestActionMatch(selectedLabel, near: questionIndex, in: nodes),
               let containerIndex = questionContainer(
                   questionIndex: questionIndex,
                   optionIndex: optionIndex,
                   questionText: question.question,
                   in: nodes
               ),
               let submitIndex = bestSubmitAction(
                   in: nodes,
                   within: containerIndex,
                   excluding: pressedOptionIDs
               ) {
                try press(nodes[submitIndex].id, label: "Send")
                return
            }
            try pause(after: attempt, cancellation: cancellation)
        }
        // No separate control is normal for option rows. Rollout confirmation
        // decides whether the row press actually submitted the response.
    }

    private func pause(
        after attempt: Int,
        cancellation: CodexSubmissionCancellation
    ) throws {
        guard attempt + 1 < max(1, retryPolicy.maximumAttempts), retryPolicy.interval > 0 else { return }
        try cancellablePause(retryPolicy.interval, cancellation: cancellation)
    }

    private func cancellablePause(
        _ duration: TimeInterval,
        cancellation: CodexSubmissionCancellation
    ) throws {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            try checkCancellation(cancellation)
            Thread.sleep(forTimeInterval: min(0.025, max(0, deadline.timeIntervalSinceNow)))
        } while Date() < deadline
    }

    private func checkCancellation(_ cancellation: CodexSubmissionCancellation) throws {
        if cancellation.isCancelled { throw CodexAccessibilityError.cancelled }
    }

    // MARK: Matching

    private func bestTextMatch(_ target: String, in nodes: [CodexAccessibilityNode]) -> Int? {
        nodes.indices
            .map { ($0, textScore(nodes[$0].text, target: target)) }
            .filter { $0.1 > 0 }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    private func bestActionMatch(
        _ target: String,
        near questionIndex: Int,
        in nodes: [CodexAccessibilityNode]
    ) -> Int? {
        var best: (index: Int, score: Int)?
        for index in nodes.indices {
            let labelScore = textScore(nodes[index].text, target: target)
            guard labelScore > 0,
                  let actionIndex = pressableAncestor(from: index, in: nodes)
            else { continue }
            let score = labelScore - treeDistance(questionIndex, actionIndex, in: nodes) * 12
            if best == nil || score > best!.score { best = (actionIndex, score) }
        }
        return best?.index
    }

    private func lowestCommonAncestor(
        _ lhs: Int,
        _ rhs: Int,
        in nodes: [CodexAccessibilityNode]
    ) -> Int? {
        var ancestors: Set<Int> = []
        var cursor: Int? = lhs
        while let current = cursor {
            ancestors.insert(current)
            cursor = nodes[current].parent
        }
        cursor = rhs
        while let current = cursor {
            if ancestors.contains(current) { return current }
            cursor = nodes[current].parent
        }
        return nil
    }

    /// Electron exposes the whole question sheet as an AXGroup whose semantic
    /// text contains the prompt. Prefer that boundary over the option's local
    /// row group so a sibling Submit button is included, while the main composer
    /// remains outside. Synthetic/minimal trees fall back to the option LCA.
    private func questionContainer(
        questionIndex: Int,
        optionIndex: Int,
        questionText: String,
        in nodes: [CodexAccessibilityNode]
    ) -> Int? {
        var container = lowestCommonAncestor(questionIndex, optionIndex, in: nodes)
        var cursor = nodes[questionIndex].parent
        while let current = cursor {
            if nodes[current].role == kAXGroupRole,
               textScore(nodes[current].text, target: questionText) > 0 {
                container = current
            }
            cursor = nodes[current].parent
        }
        return container
    }

    private func isDescendant(
        _ index: Int,
        of ancestor: Int,
        in nodes: [CodexAccessibilityNode]
    ) -> Bool {
        var cursor: Int? = index
        while let current = cursor {
            if current == ancestor { return true }
            cursor = nodes[current].parent
        }
        return false
    }

    private func nearestEditable(near questionIndex: Int, in nodes: [CodexAccessibilityNode]) -> Int? {
        nodes.indices
            .filter { nodes[$0].role == kAXTextFieldRole || nodes[$0].role == kAXTextAreaRole }
            .min { treeDistance(questionIndex, $0, in: nodes) < treeDistance(questionIndex, $1, in: nodes) }
    }

    private func bestSubmitAction(
        in nodes: [CodexAccessibilityNode],
        within containerIndex: Int,
        excluding nodeIDs: Set<Int>
    ) -> Int? {
        let labels = ["Submit answers", "Submit", "Send", "Continue", "Done"]
        var best: (index: Int, score: Int)?
        for index in nodes.indices where nodes[index].actions.contains(kAXPressAction) {
            guard !nodeIDs.contains(nodes[index].id),
                  isDescendant(index, of: containerIndex, in: nodes)
            else { continue }
            for (priority, label) in labels.enumerated() {
                let score = textScore(nodes[index].text, target: label) - priority
                if score > 0, best == nil || score > best!.score { best = (index, score) }
            }
        }
        return best?.index
    }

    private func pressableAncestor(from index: Int, in nodes: [CodexAccessibilityNode]) -> Int? {
        var cursor: Int? = index
        var climbed = 0
        while let current = cursor, climbed <= 6 {
            if nodes[current].actions.contains(kAXPressAction) { return current }
            cursor = nodes[current].parent
            climbed += 1
        }
        return nil
    }

    private func treeDistance(_ lhs: Int, _ rhs: Int, in nodes: [CodexAccessibilityNode]) -> Int {
        var ancestors: [Int: Int] = [:]
        var cursor: Int? = lhs
        var distance = 0
        while let current = cursor {
            ancestors[current] = distance
            cursor = nodes[current].parent
            distance += 1
        }
        cursor = rhs
        distance = 0
        while let current = cursor {
            if let leftDistance = ancestors[current] { return leftDistance + distance }
            cursor = nodes[current].parent
            distance += 1
        }
        return 100
    }

    private func textScore(_ candidate: String, target: String) -> Int {
        let candidate = normalize(candidate)
        let target = normalize(target)
        guard !candidate.isEmpty, !target.isEmpty else { return 0 }
        if candidate == target { return 1_000 }
        if candidate.hasPrefix(target) || candidate.hasSuffix(target) { return 800 }
        if candidate.contains(target) { return 600 }
        return 0
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func press(_ nodeID: Int, label: String) throws {
        guard controller.press(nodeID: nodeID) else {
            throw CodexAccessibilityError.actionFailed(label)
        }
    }
}
