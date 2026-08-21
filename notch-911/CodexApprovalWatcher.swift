//
//  CodexApprovalWatcher.swift
//  notch-911
//
//  Codex approval prompts, detected from Codex's own rollout logs — the same
//  observe-don't-own channel the plan-question and completion watchers use.
//
//  An approval is not a record type of its own: it is an ordinary tool call
//  whose input carries an escalation marker (`require_escalated` /
//  `with_escalated_permissions`) and a human-readable `justification` — the
//  exact sentence Codex shows next to its Allow/Deny buttons. While the call
//  has no output record, the turn is blocked on the user. When the output
//  lands, it was answered.
//
//  Disk is the detection channel because it is the only one that works from
//  every Space: hooks never run (proven), and the Accessibility tree cannot
//  see a window on another desktop. Accessibility still has one job here —
//  *answering*. Pressing the real Allow/Deny button requires the window to be
//  on the current Space, which is why the caller falls back to activating
//  Codex when a press cannot land.
//

import AppKit
import ApplicationServices
import Foundation

nonisolated struct CodexPendingApproval: Sendable, Equatable {
    /// The tool call's `call_id` — unique per approval, stable across polls.
    let callID: String
    let sessionID: String
    let cwd: String
    /// The `justification` string — what Codex's own UI shows as the question.
    let question: String
    let receivedAt: Date
}

nonisolated struct CodexApprovalChanges: Sendable {
    var appeared: [CodexPendingApproval] = []
    var resolvedIDs: [String] = []
}

/// The slice of Accessibility the presser needs. Tests provide deterministic
/// trees without controlling a real app.
nonisolated protocol CodexApprovalTreeReading: Sendable {
    var isTrusted: Bool { get }
    /// The forest under the app's windows, or nil when no window is visible —
    /// which on macOS includes "the window is on another Space".
    func windowNodes(processID: pid_t) -> [CodexAccessibilityNode]?
    func press(nodeID: Int) -> Bool
}

/// File and AX work stays off the main actor.
actor CodexApprovalWatcher {

    static let bundleID = "com.openai.codex"

    /// Labels Codex uses on its approval buttons. Matched exactly, lowercased —
    /// substring matching would catch "Allow notifications" in a settings pane.
    private static let allowLabels: Set<String> = [
        "allow once", "allow", "always allow", "allow for session", "approve",
    ]
    private static let denyLabels: Set<String> = [
        "deny", "decline", "don't allow", "reject",
    ]

    /// On launch, a pending approval younger than this is recovered onto the
    /// notch; older ones are treated as abandoned. Generous on purpose — a
    /// relaunch mid-question should not eat the card — but bounded, because an
    /// interrupted turn leaves its call dangling forever.
    private static let recoveryWindow: TimeInterval = 30 * 60

    private struct FileSnapshot {
        let modifiedAt: Date
        let pending: [String: CodexPendingApproval]
    }

    private let sessionsRoot: URL
    private let reader: any CodexApprovalTreeReading
    private let processID: @Sendable () -> pid_t?
    private var files: [String: FileSnapshot] = [:]
    private var delivered: Set<String> = []
    private var active: Set<String> = []
    private var hasPolled = false

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        reader: any CodexApprovalTreeReading = SystemCodexApprovalTreeReader(),
        processID: @escaping @Sendable () -> pid_t? = {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.processIdentifier
        }
    ) {
        sessionsRoot = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        self.reader = reader
        self.processID = processID
    }

    // MARK: Detection (rollouts)

    func poll(now: Date = Date()) -> CodexApprovalChanges {
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
            files[url.path] = FileSnapshot(modifiedAt: modifiedAt, pending: Self.parse(url: url))
        }

        let unresolved = files.values.reduce(into: [String: CodexPendingApproval]()) { result, file in
            result.merge(file.pending) { old, new in
                old.receivedAt >= new.receivedAt ? old : new
            }
        }
        let ids = Set(unresolved.keys)
        let resolved = active.subtracting(ids).filter { delivered.contains($0) }
        active = ids

        if !hasPolled {
            hasPolled = true
            let cutoff = now.addingTimeInterval(-Self.recoveryWindow)
            delivered.formUnion(unresolved.values
                .filter { $0.receivedAt < cutoff }
                .map(\.callID))
        }

        let appeared = unresolved.values
            .filter { !delivered.contains($0.callID) }
            .sorted { $0.receivedAt < $1.receivedAt }
        delivered.formUnion(appeared.map(\.callID))

        return CodexApprovalChanges(appeared: appeared, resolvedIDs: Array(resolved))
    }

    /// Forgets cards resolved by an outside signal — today, the turn-complete
    /// record: a completed turn cannot still be waiting on an approval.
    func resolveExternally(_ ids: [String]) {
        for id in ids {
            delivered.remove(id)
            active.remove(id)
        }
    }

    // MARK: Answering (Accessibility)

    /// Presses the real button in the Codex window for the given question.
    /// Returns false when the window is on another Space, the prompt is gone,
    /// or the press fails — the caller owns the fallback.
    func press(question: String, allow: Bool) -> Bool {
        guard reader.isTrusted, let pid = processID(),
              let nodes = reader.windowNodes(processID: pid)
        else { return false }

        let clusters = Self.approvals(in: nodes)
        // Match on the justification text Codex renders next to its buttons.
        // When only one approval is on screen, that one is the answer even if
        // the rendered text was truncated or re-wrapped.
        let target = clusters.first(where: {
            $0.question == question || $0.question.hasPrefix(question) || question.hasPrefix($0.question)
        }) ?? (clusters.count == 1 ? clusters.first : nil)
        guard let target else { return false }

        let wanted = (allow ? target.allowLabel : target.denyLabel).lowercased()
        guard let button = nodes.first(where: {
            $0.role == "AXButton" && $0.text.lowercased() == wanted
        }) else { return false }
        return reader.press(nodeID: button.id)
    }

    // MARK: Rollout parsing

    /// Today and yesterday, so an approval pending across midnight stays found.
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

    /// Pending escalated calls in one rollout: an escalation-marked tool call
    /// with no output record, and no turn boundary (completion, new user
    /// message, new turn) after it — a boundary means the turn moved on, so
    /// the call can never be answered again whatever else it is.
    static func parse(url: URL) -> [String: CodexPendingApproval] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [:] }

        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        struct Candidate { let approval: CodexPendingApproval; let line: Int }
        var candidates: [String: Candidate] = [:]
        var completed: Set<String> = []
        var lastBoundaryLine = -1

        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
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
                if let kind = payload["type"] as? String,
                   ["task_complete", "task_started", "user_message"].contains(kind) {
                    lastBoundaryLine = index
                }
                continue
            case "response_item":
                break
            default:
                continue
            }

            let payloadType = payload["type"] as? String
            if payloadType == "custom_tool_call_output" || payloadType == "function_call_output",
               let callID = payload["call_id"] as? String {
                completed.insert(callID)
                continue
            }
            guard payloadType == "custom_tool_call" || payloadType == "function_call",
                  let callID = payload["call_id"] as? String
            else { continue }

            // Approvals come in (at least) two shapes, both ordinary tool
            // calls: an escalated command (`sandbox_permissions:
            // "require_escalated"` with a `justification`) and a direct
            // permission grant (`tools.request_permissions` with a `reason`).
            // The marker and the question both live in the call's argument
            // text — a JS snippet for `custom_tool_call`, a JSON blob for
            // `function_call` — so a plain text search covers all of it.
            let argumentText = (payload["input"] as? String ?? "")
                + (payload["arguments"] as? String ?? "")
            guard argumentText.contains("require_escalated")
                || argumentText.contains("with_escalated_permissions")
                || argumentText.contains("request_permissions")
            else { continue }
            guard let question = Self.justification(in: argumentText) else { continue }

            let timestamp = (root["timestamp"] as? String).flatMap(Self.parseDate) ?? Date()
            candidates[callID] = Candidate(
                approval: CodexPendingApproval(
                    callID: callID,
                    sessionID: sessionID,
                    cwd: cwd,
                    question: question,
                    receivedAt: timestamp
                ),
                line: index
            )
        }

        var pending: [String: CodexPendingApproval] = [:]
        for (callID, candidate) in candidates {
            guard !completed.contains(callID), candidate.line > lastBoundaryLine else { continue }
            pending[callID] = candidate.approval
        }
        return pending
    }

    /// Pulls the human-readable question out of the call's argument text:
    /// `justification` for escalated commands, `reason` for direct
    /// `request_permissions` grants. Handles JS (`key: "…"`) and JSON
    /// (`"key":"…"`) spellings, including escaped quotes inside the string.
    static func justification(in text: String) -> String? {
        guard let range = text.range(
            of: #""?(justification|reason)"?\s*:\s*""#,
            options: .regularExpression
        )
        else { return nil }
        var result = ""
        var escaped = false
        for character in text[range.upperBound...] {
            if escaped {
                switch character {
                case "n": result.append(" ")
                case "t": result.append(" ")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                result.append(character)
            }
        }
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private nonisolated static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    // MARK: On-screen cluster matching (for the press)

    nonisolated struct ApprovalCluster: Sendable {
        let question: String
        let allowLabel: String
        let denyLabel: String
    }

    /// Finds allow/deny button pairs and the question they belong to.
    ///
    /// Anchored on the deny button: every Codex approval has one, and "Deny" is
    /// the rarer word in a chat transcript than "Allow". The allow button must
    /// share its parent; the question is the longest static text under the
    /// nearest ancestor that has one, which in the current UI is the approval
    /// card's container.
    static func approvals(in nodes: [CodexAccessibilityNode]) -> [ApprovalCluster] {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenOf: [Int: [CodexAccessibilityNode]] = [:]
        for node in nodes {
            if let parent = node.parent { childrenOf[parent, default: []].append(node) }
        }

        func subtreeTexts(_ root: Int, depth: Int = 0) -> [String] {
            guard depth <= 6 else { return [] }
            var texts: [String] = []
            for child in childrenOf[root] ?? [] {
                if child.role == "AXStaticText", !child.text.isEmpty { texts.append(child.text) }
                texts.append(contentsOf: subtreeTexts(child.id, depth: depth + 1))
            }
            return texts
        }

        var result: [ApprovalCluster] = []
        var claimed: Set<Int> = []

        for deny in nodes where deny.role == "AXButton"
            && Self.denyLabels.contains(deny.text.lowercased())
            && !claimed.contains(deny.id) {

            guard let parent = deny.parent,
                  let allow = (childrenOf[parent] ?? []).first(where: {
                      $0.role == "AXButton" && Self.allowLabels.contains($0.text.lowercased())
                  })
            else { continue }

            var container = parent
            var question = ""
            for _ in 0..<4 {
                let texts = subtreeTexts(container)
                    .filter { $0.count >= 8 && $0.lowercased() != deny.text.lowercased() }
                if let best = texts.max(by: { $0.count < $1.count }) {
                    question = best
                    break
                }
                guard let up = byID[container]?.parent else { break }
                container = up
            }
            guard !question.isEmpty else { continue }

            claimed.insert(deny.id)
            claimed.insert(allow.id)
            result.append(ApprovalCluster(
                question: question,
                allowLabel: allow.text,
                denyLabel: deny.text
            ))
        }
        return result
    }
}

// MARK: - System reader

/// Walks the real tree. Windows only — the menu bar can't contain an approval,
/// and skipping it keeps the budget for the transcript.
nonisolated final class SystemCodexApprovalTreeReader: CodexApprovalTreeReading, @unchecked Sendable {

    /// Sized for a long transcript, not a sheet. At ~5 AX calls per node this
    /// is the poll's cost ceiling; typical trees stay well under it.
    private static let nodeBudget = 20_000
    private static let depthLimit = 60

    private let lock = NSLock()
    private var elements: [Int: AXUIElement] = [:]

    var isTrusted: Bool { AXIsProcessTrusted() }

    func windowNodes(processID: pid_t) -> [CodexAccessibilityNode]? {
        let root = AXUIElementCreateApplication(processID)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty
        else { return nil }

        var result: [CodexAccessibilityNode] = []
        var captured: [Int: AXUIElement] = [:]
        var queue: [(AXUIElement, Int?, Int)] = windows.map { ($0, nil, 0) }
        var cursor = 0

        while cursor < queue.count, result.count < Self.nodeBudget {
            let (element, parent, depth) = queue[cursor]
            cursor += 1
            guard depth <= Self.depthLimit else { continue }

            let id = Int(CFHash(element))
            captured[id] = element
            result.append(CodexAccessibilityNode(
                id: id,
                parent: parent,
                role: stringValue(element, attribute: kAXRoleAttribute),
                text: accessibleText(element),
                actions: []
            ))
            for child in children(element) {
                queue.append((child, id, depth + 1))
            }
        }

        lock.lock()
        elements = captured
        lock.unlock()
        return result
    }

    func press(nodeID: Int) -> Bool {
        lock.lock()
        let element = elements[nodeID]
        lock.unlock()
        guard let element else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func stringValue(_ element: AXUIElement, attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let string = value as? String
        else { return "" }
        return string
    }

    private func accessibleText(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
            .map { stringValue(element, attribute: $0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
