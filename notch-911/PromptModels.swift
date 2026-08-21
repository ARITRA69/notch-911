//
//  PromptModels.swift
//  notch-911
//
//  The generalised prompt model. M0 could only ask "allow or deny"; this covers
//  every shape the two agents can actually put in front of a user:
//
//    permission  — allow / deny            (PermissionRequest, both agents)
//    question    — selects + Other         (AskUserQuestion, Claude Code only)
//    form        — selects + text fields   (Elicitation, Claude Code only)
//    freeText    — one text field          (Stop, both agents)
//
//  Codex has no elicitation hook. Plan-mode questions are observed from its
//  local rollout log and answered through the existing Codex UI with macOS
//  Accessibility.
//

import Foundation

// MARK: - Which hook produced this

nonisolated enum HookEventKind: String, Sendable {
    case permissionRequest = "PermissionRequest"
    case elicitation = "Elicitation"
    case stop = "Stop"
    case userInputRequest = "RequestUserInput"
}

// MARK: - Field model

nonisolated struct Choice: Sendable, Identifiable, Hashable {
    let id = UUID()
    /// What goes back on the wire.
    let value: String
    /// What the user reads.
    let label: String
}

// MARK: - AskUserQuestion model

nonisolated struct AskOption: Sendable, Identifiable, Hashable {
    var id: String { label }
    let label: String
    let detail: String?
}

nonisolated struct AskQuestion: Sendable, Identifiable, Hashable {
    /// Position within the call. The schema requires neither headers nor
    /// question texts to be distinct, so the index is the only stable identity.
    let id: Int
    let header: String
    let question: String
    let multiSelect: Bool
    let options: [AskOption]
}

/// What the user picked for one question. `otherText` carries the free-form
/// entry; on a multi-select it can accompany `selectedLabels`, on a single
/// select exactly one of the two is populated.
nonisolated struct AskAnswer: Sendable, Equatable {
    let question: AskQuestion
    /// In the question's option order, not selection order.
    let selectedLabels: [String]
    let otherText: String?
}

// MARK: - Codex App question model

nonisolated struct CodexQuestionOption: Sendable, Identifiable, Hashable {
    var id: String { label }
    let label: String
    let detail: String?
}

nonisolated struct CodexQuestion: Sendable, Identifiable, Hashable {
    let id: String
    let header: String
    let question: String
    let options: [CodexQuestionOption]
    /// The Codex client adds Other even though it is not present in the model's
    /// tool arguments, so observed questions always support a free-form answer.
    let allowsOther: Bool
}

nonisolated struct CodexQuestionAnswer: Sendable, Equatable {
    let questionID: String
    /// Exactly one of `selectedLabel` and `otherText` is non-nil.
    let selectedLabel: String?
    let otherText: String?
}

nonisolated enum FormInput: Sendable {
    case text(placeholder: String?)
    case number(isInteger: Bool)
    case toggle
    case singleSelect([Choice])
    case multiSelect([Choice])
}

nonisolated struct FormField: Sendable, Identifiable {
    let id = UUID()
    /// The JSON key this field's value is returned under.
    let name: String
    let title: String
    let detail: String?
    let isRequired: Bool
    let input: FormInput
}

// MARK: - Prompt

nonisolated enum PromptKind: Sendable {
    case permission
    case question([AskQuestion])
    case form([FormField])
    case freeText(placeholder: String)
    case externalQuestion

    var isPermission: Bool {
        if case .permission = self { return true }
        return false
    }

    /// True when the surface contains a text field, which changes the keyboard
    /// map: bare digits would otherwise be swallowed by typing.
    var hasTextEntry: Bool {
        switch self {
        case .permission: return false
        case .freeText: return true
        // The Other entry appears mid-interaction, so the keyboard map has to
        // assume a text field from the start.
        case .question: return true
        case .externalQuestion: return false
        case .form(let fields):
            return fields.contains {
                switch $0.input {
                case .text, .number: return true
                case .toggle, .singleSelect, .multiSelect: return false
                }
            }
        }
    }
}

/// One blocked question, flattened for display. Built off-main and handed to the
/// UI fully formed — §7.2 forbids parsing during animation.
nonisolated struct Prompt: Sendable, Identifiable {
    let id = UUID()
    let agent: Agent
    let event: HookEventKind
    let sessionId: String
    let cwd: String
    /// Tool name, or the elicitation/stop headline.
    let title: String
    /// One-line gist under the title. May be empty.
    let summary: String
    let kind: PromptKind
    let receivedAt: Date
    /// Stable source identifier used to deduplicate observed, non-hook prompts.
    var externalID: String? = nil
    /// Full App Server question form. Hook-backed prompts leave this empty.
    var codexQuestions: [CodexQuestion] = []

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "unknown" : name
    }
}

// MARK: - Building a prompt from a hook payload

extension Prompt {

    /// Flattens a hook body into something renderable. Returns nil only when the
    /// body isn't JSON at all — every other malformed case degrades to a usable
    /// prompt, because a session blocked forever is worse than a vague question.
    static func make(agent: Agent, event: HookEventKind, body: Data) -> Prompt? {
        guard let payload = try? HookPayload.decode(body) else { return nil }
        let raw = try? JSONDecoder().decode(JSONValue.self, from: body)

        let title: String
        let summary: String
        let kind: PromptKind

        switch event {
        case .permissionRequest:
            // AskUserQuestion renders as an answerable form: the pick goes back
            // as a deny-with-message the model reads as the user's answer (see
            // `PromptResponse.body`). A payload we can't parse degrades to the
            // generic allow / deny card, which still unblocks the session.
            if payload.toolName == "AskUserQuestion",
               let questions = AskUserQuestionInput.parse(payload.toolInput) {
                title = questions[0].question
                summary = ""
                kind = .question(questions)
            } else {
                title = payload.toolName ?? "Unknown tool"
                summary = ToolSummary.lead(tool: payload.toolName, input: payload.toolInput)
                kind = .permission
            }

        case .elicitation:
            // The request payload isn't documented, so fall back to a bounded
            // search before giving up on the schema.
            let schema = payload.requestedSchema
                ?? search(["requestedSchema", "requested_schema", "schema"], in: raw)
            let message = payload.message
                ?? search(["message", "prompt"], in: raw)?.scalarString
            title = message ?? "Input requested"
            summary = payload.toolName ?? ""
            // An empty field list still renders — as a bare Accept / Decline,
            // which is exactly the right degradation for an unparseable schema.
            kind = .form(
                ElicitationSchema.fields(
                    from: schema,
                    rawBody: String(data: body, encoding: .utf8)
                )
            )

        case .stop:
            title = "Anything else?"
            summary = payload.lastAssistantMessage.map {
                $0.count > 160 ? String($0.prefix(160)) + "…" : $0
            } ?? ""
            kind = .freeText(placeholder: "Reply to continue, or dismiss to end the turn")

        case .userInputRequest:
            // Constructed by `CodexPlanQuestionWatcher`, never from a hook body.
            return nil
        }

        return Prompt(
            agent: agent,
            event: event,
            sessionId: payload.sessionId ?? "unknown",
            cwd: payload.cwd ?? "",
            title: title,
            summary: summary,
            kind: kind,
            receivedAt: Date(),
            externalID: nil,
            codexQuestions: []
        )
    }

    /// Breadth-ish search for a key the payload may nest. Bounded in depth so a
    /// pathological payload can't spin, and key-sorted so it is deterministic.
    private static func search(_ keys: [String], in value: JSONValue?, depth: Int = 0) -> JSONValue? {
        guard let value, depth < 4, case .object(let dict) = value else { return nil }
        for key in keys where dict[key] != nil { return dict[key] }
        for key in dict.keys.sorted() {
            if let hit = search(keys, in: dict[key], depth: depth + 1) { return hit }
        }
        return nil
    }
}

/// `AskUserQuestion`'s arguments, parsed in full so the notch can collect the
/// answer itself. Degrades per-question rather than failing whole: a missing
/// header renders blank, missing options leave just the Other entry, and only a
/// call with no readable question at all returns nil — that case falls back to
/// the generic permission card.
nonisolated enum AskUserQuestionInput {
    static func parse(_ input: JSONValue?) -> [AskQuestion]? {
        guard let input, case .array(let items)? = input["questions"] else { return nil }

        let questions = items.enumerated().compactMap { index, item -> AskQuestion? in
            guard let text = item["question"]?.scalarString, !text.isEmpty else { return nil }

            var options: [AskOption] = []
            if case .array(let raw)? = item["options"] {
                // Labels double as identity (and as the wire value in the deny
                // message), so a duplicate is dropped rather than rendered as
                // two rows that select together.
                var seen = Set<String>()
                options = raw.compactMap { option in
                    guard let label = option["label"]?.scalarString, !label.isEmpty,
                          seen.insert(label).inserted
                    else { return nil }
                    return AskOption(label: label, detail: option["description"]?.scalarString)
                }
            }

            var multiSelect = false
            if case .bool(let flag)? = item["multiSelect"] { multiSelect = flag }

            return AskQuestion(
                id: index,
                header: item["header"]?.scalarString ?? "",
                question: text,
                multiSelect: multiSelect,
                options: options
            )
        }
        return questions.isEmpty ? nil : questions
    }
}

// MARK: - Response

nonisolated enum FormAction: String, Sendable {
    case accept, decline, cancel
}

nonisolated enum PromptResponse: Sendable {
    case permission(PermissionDecision)
    /// Answers to an `AskUserQuestion` call, one per question.
    case answers([AskAnswer])
    case form(action: FormAction, values: [String: JSONValue])
    /// Empty text means "nothing to add" — the turn ends normally.
    case text(String)

    /// Serialises into whatever the originating hook expects. Returning `nil`
    /// means "no decision": the caller emits an empty 200 and the agent falls
    /// back to its own flow (§11).
    func body(for event: HookEventKind) -> Data? {
        switch (event, self) {
        case (.permissionRequest, .permission(let decision)):
            return decision.responseBody()

        // PermissionRequest can only allow or deny a tool call — nothing in the
        // hook schema returns a tool's *result*. So the selections ride the
        // deny message: Claude Code hands it to the model as the reason the
        // call was refused, and the model reads it as the user's answer.
        case (.permissionRequest, .answers(let answers)):
            return PermissionDecision.deny.responseBody(message: AskAnswer.denyMessage(answers))

        case (.elicitation, .form(let action, let values)):
            var output: [String: Any] = [
                "hookEventName": HookEventKind.elicitation.rawValue,
                "action": action.rawValue,
            ]
            // `content` is only meaningful on accept.
            if action == .accept {
                output["content"] = values.mapValues(\.foundationValue)
            }
            return try? JSONSerialization.data(
                withJSONObject: ["hookSpecificOutput": output],
                options: [.withoutEscapingSlashes]
            )

        case (.stop, .text(let text)):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing typed → let the turn end rather than blocking on empty.
            guard !trimmed.isEmpty else { return nil }
            return try? JSONSerialization.data(
                withJSONObject: ["decision": "block", "reason": trimmed],
                options: [.withoutEscapingSlashes]
            )

        default:
            return nil
        }
    }
}

extension AskAnswer {
    /// The deny message carrying the selections back to the model. Worded as an
    /// instruction, not just data — a bare list reads as a refusal and invites
    /// the model to ask the same thing again.
    nonisolated static func denyMessage(_ answers: [AskAnswer]) -> String {
        var lines = [
            "The user answered in the notch (notch-911) instead of the session picker. "
            + "These are their final selections — continue with them and do not re-ask:"
        ]
        for answer in answers {
            var picks = answer.selectedLabels
            if let other = answer.otherText, !other.isEmpty { picks.append(other) }
            lines.append("")
            lines.append("Q: \(answer.question.question)")
            lines.append("A: \(picks.isEmpty ? "(no selection)" : picks.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - MCP elicitation schema → fields

extension JSONValue {
    /// Converts back to a plain Foundation value for JSONSerialization.
    ///
    /// Explicitly nonisolated: the project defaults to MainActor isolation, and
    /// this runs on the server's queue while encoding a response.
    nonisolated var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() ? Int(n) : n
        case .string(let s): return s
        case .array(let items): return items.map(\.foundationValue)
        case .object(let dict): return dict.mapValues(\.foundationValue)
        }
    }
}

nonisolated enum ElicitationSchema {

    /// Parses an MCP `requestedSchema` into renderable fields.
    ///
    /// MCP restricts elicitation schemas to a flat object of primitives, so this
    /// deliberately handles only one level. Anything unrecognised degrades to a
    /// text field rather than being dropped — a field the user can still fill in
    /// beats a field that silently vanishes (§13).
    ///
    /// `rawBody` exists purely to recover field order. Parsed JSON objects are
    /// unordered, but the schema author's order is meaningful — asking "release
    /// note" before "deploy target" is a worse question than the one that was
    /// written. Sorting by first appearance in the raw text restores it.
    static func fields(from schema: JSONValue?, rawBody: String? = nil) -> [FormField] {
        guard let schema, case .object(let root) = schema,
              case .object(let properties)? = root["properties"]
        else { return [] }

        let required: Set<String>
        if case .array(let items)? = root["required"] {
            required = Set(items.compactMap(\.scalarString))
        } else {
            required = []
        }

        let ordered = properties.keys.sorted { lhs, rhs in
            let left = position(of: lhs, in: rawBody)
            let right = position(of: rhs, in: rawBody)
            // Alphabetical only as a tiebreak, so ordering stays deterministic
            // when the raw text is unavailable.
            return left == right ? lhs < rhs : left < right
        }

        return ordered.map { key in
            let spec = properties[key]!
            return FormField(
                name: key,
                title: spec["title"]?.scalarString ?? key,
                detail: spec["description"]?.scalarString,
                isRequired: required.contains(key),
                input: input(for: spec)
            )
        }
    }

    /// Byte offset of a property key's first appearance. A key name that also
    /// occurs earlier as a *value* would sort early — harmless, since the worst
    /// case is a slightly odd order, never a dropped field.
    private static func position(of key: String, in rawBody: String?) -> Int {
        guard let rawBody, let range = rawBody.range(of: "\"\(key)\"") else { return .max }
        return rawBody.distance(from: rawBody.startIndex, to: range.lowerBound)
    }

    private static func input(for spec: JSONValue) -> FormInput {
        // A bare `enum` is a single select.
        if let choices = choices(in: spec) {
            return .singleSelect(choices)
        }

        let type = spec["type"]?.scalarString

        // An array of enums is a multi select. Not part of the base MCP
        // elicitation spec, but servers do send it and it is the natural
        // representation of "pick several".
        if type == "array", let items = spec["items"], let choices = choices(in: items) {
            return .multiSelect(choices)
        }

        switch type {
        case "boolean": return .toggle
        case "number": return .number(isInteger: false)
        case "integer": return .number(isInteger: true)
        default:
            return .text(placeholder: spec["description"]?.scalarString)
        }
    }

    /// `enum` carries the wire values; the parallel `enumNames` carries labels.
    private static func choices(in spec: JSONValue) -> [Choice]? {
        guard case .array(let values)? = spec["enum"] else { return nil }
        var names: [String] = []
        if case .array(let labels)? = spec["enumNames"] {
            names = labels.compactMap(\.scalarString)
        }
        let choices = values.enumerated().compactMap { index, value -> Choice? in
            guard let raw = value.scalarString else { return nil }
            return Choice(value: raw, label: index < names.count ? names[index] : raw)
        }
        return choices.isEmpty ? nil : choices
    }
}

// MARK: - Turn completion

/// "The agent finished" — the one notch surface that isn't a question.
///
/// Deliberately not a `Prompt`. A `Prompt` exists to carry an answer back to a
/// blocked agent, and every part of that machinery — the continuation map, the
/// waiting queue, the keyboard map — is wrong for something nobody has to
/// answer. Announcing a completion must never hold a turn open, so this rides
/// its own path and the hook it came from is released immediately.
nonisolated struct CompletionNotice: Sendable, Identifiable, Equatable {
    let id: UUID
    let agent: Agent
    let cwd: String
    /// The agent's closing message, already trimmed for display. May be empty.
    let summary: String
    /// Wall time for the turn, when the source knew it. Claude Code's `Stop`
    /// payload doesn't carry one; Codex's rollout record does.
    let duration: TimeInterval?
    let receivedAt: Date

    init(
        id: UUID = UUID(),
        agent: Agent,
        cwd: String,
        summary: String,
        duration: TimeInterval? = nil,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.agent = agent
        self.cwd = cwd
        self.summary = Self.trim(summary)
        self.duration = duration
        self.receivedAt = receivedAt
    }

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "unknown" : name
    }

    /// `4s`, `1m 12s`. Nil when the source didn't report one, which the card
    /// reads as "show nothing" rather than "show zero".
    var durationText: String? {
        guard let duration, duration >= 1 else { return nil }
        let total = Int(duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }

    /// One line, bounded. The banner is on screen for a few seconds and sized
    /// for a glance — a closing message can run to paragraphs, and letting it
    /// set the panel's height would make the notch lurch open at full size.
    private static func trim(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = flattened.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let cleaned = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 140 ? String(cleaned.prefix(140)) + "…" : cleaned
    }
}
