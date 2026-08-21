//
//  HookModels.swift
//  notch-911
//
//  M0 spike: the wire format between Claude Code's hook system and this app.
//  Only PermissionRequest is modelled — Elicitation and Stop land in M2.
//

import Foundation

// MARK: - Loosely-typed JSON

/// `tool_input` has a different shape for every tool, so it is decoded into a
/// generic tree rather than a per-tool struct.
nonisolated enum JSONValue: Decodable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised JSON value"
            )
        }
    }

    /// The value as a plain string when it is a scalar, otherwise nil.
    var scalarString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        case .null: return nil
        case .array, .object: return nil
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    /// Human-readable rendering used for the detail body in the panel.
    func prettyPrinted(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .null: return "null"
        case .bool(let b): return String(b)
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .array(let items):
            return items.map { "\(pad)- \($0.prettyPrinted(indent: indent + 1))" }
                .joined(separator: "\n")
        case .object(let dict):
            return dict.keys.sorted().map { key in
                let value = dict[key]!.prettyPrinted(indent: indent + 1)
                return value.contains("\n")
                    ? "\(pad)\(key):\n\(value)"
                    : "\(pad)\(key): \(value)"
            }.joined(separator: "\n")
        }
    }
}

// MARK: - Inbound

/// The subset of the hook payload M0 reads. Decoded with `.convertFromSnakeCase`,
/// so `tool_name` on the wire maps to `toolName` here.
///
/// Everything is optional on purpose: an unexpected payload from a future Claude
/// Code release must degrade to a partially-populated prompt, never a decode
/// failure that leaves the session blocked.
nonisolated struct HookPayload: Decodable, Sendable {
    var sessionId: String?
    var cwd: String?
    var hookEventName: String?
    var permissionMode: String?
    var toolName: String?
    var toolInput: JSONValue?
    var toolUseId: String?

    // Elicitation. The hook reference documents the *response* shape but not the
    // request payload, so these are decoded optimistically and backed up by a
    // raw search in `Prompt.make`.
    var message: String?
    var requestedSchema: JSONValue?

    // Stop.
    var lastAssistantMessage: String?
    var stopReason: String?

    static func decode(_ data: Data) throws -> HookPayload {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(HookPayload.self, from: data)
    }
}

// MARK: - View model

/// Which agent is blocked. Both speak the same `PermissionRequest` schema; they
/// differ only in how the event reaches us (Claude Code POSTs directly, Codex
/// goes through the shim in `CodexSettings`).
nonisolated enum Agent: String, Sendable {
    case claudeCode
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The desktop client to bring forward when a completion banner is
    /// clicked. Codex's is `ChatGPT.app`, which carries the `com.openai.codex`
    /// identifier rather than a ChatGPT one — the Codex desktop client is
    /// shipped inside it.
    ///
    /// Claude Code is the looser fit of the two: it runs just as happily in a
    /// terminal, and there is no way to ask a hook payload which window it came
    /// from. Claude for Desktop is the best available guess, and a wrong guess
    /// costs one unwanted app activation.
    var desktopBundleID: String {
        switch self {
        case .claudeCode: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.codex"
        }
    }

    /// The agent's own mark, in `Assets.xcassets/Logos`. Codex is OpenAI's, and
    /// is the one mark of the four that ships monochrome.
    var logoAsset: String {
        switch self {
        case .claudeCode: return "logo.claude"
        case .codex: return "logo.openai"
        }
    }
}

nonisolated enum ToolSummary {
    /// Preferred argument to lead with, per tool. Falls back to the full dump.
    static func lead(tool: String?, input: JSONValue?) -> String {
        guard let input else { return tool ?? "" }

        let preferredKeys: [String]
        switch tool {
        // `shell` and `apply_patch` are Codex's names for the same two things.
        case "Bash", "shell", "exec": preferredKeys = ["command"]
        case "apply_patch": preferredKeys = ["patch", "file_path"]
        case "Read", "Write", "Edit", "NotebookEdit": preferredKeys = ["file_path"]
        case "WebFetch", "WebSearch": preferredKeys = ["url", "query"]
        case "Glob", "Grep": preferredKeys = ["pattern"]
        default: preferredKeys = ["command", "file_path", "url", "path", "query"]
        }
        for key in preferredKeys {
            if let value = input[key]?.scalarString, !value.isEmpty { return value }
        }
        return input.prettyPrinted()
    }
}

// MARK: - Outbound

/// The decision the user made. Serialised into the exact shape Claude Code
/// expects back from a `PermissionRequest` hook.
nonisolated enum PermissionDecision: String, Sendable {
    case allow
    case deny

    /// `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
    ///
    /// `message` rides only on deny — the schema's channel for telling the
    /// model *why*, which is how an answered AskUserQuestion carries its
    /// selections back. Everything else stays minimal: no `updatedInput`, no
    /// `interrupt` (that would end the turn instead of continuing with the
    /// answer), because extra keys risk tripping schema validation.
    func responseBody(message: String? = nil) -> Data {
        let payload = PermissionRequestHookOutput(
            hookSpecificOutput: .init(decision: .init(behavior: rawValue, message: message))
        )
        return (try? JSONEncoder().encode(payload)) ?? Data()
    }
}

nonisolated struct PermissionRequestHookOutput: Encodable {
    struct Decision: Encodable {
        let behavior: String
        var message: String? = nil
    }

    struct Output: Encodable {
        var hookEventName = "PermissionRequest"
        let decision: Decision
    }

    let hookSpecificOutput: Output
}
