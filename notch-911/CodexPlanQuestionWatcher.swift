//
//  CodexPlanQuestionWatcher.swift
//  notch-911
//
//  Codex plan questions are App Server calls, not lifecycle hooks. The desktop
//  app persists each call and its eventual output in ~/.codex/sessions, which
//  lets us surface an unresolved question without owning the Codex session.
//

import Foundation

nonisolated struct CodexPlanQuestion: Sendable {
    let callID: String
    let sessionID: String
    let cwd: String
    let questions: [CodexQuestion]
    let receivedAt: Date
}

nonisolated struct CodexPlanQuestionChanges: Sendable {
    var appeared: [CodexPlanQuestion] = []
    var resolvedCallIDs: [String] = []
}

/// File work stays off the main actor. Only changed rollouts are reparsed, so
/// the steady-state cost is a small directory listing.
actor CodexPlanQuestionWatcher {
    private struct FileSnapshot {
        let modifiedAt: Date
        let questions: [String: CodexPlanQuestion]
    }

    private let sessionsRoot: URL
    private var files: [String: FileSnapshot] = [:]
    private var delivered: Set<String> = []
    private var active: Set<String> = []
    private let startedAt = Date()
    private var hasPolled = false

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        sessionsRoot = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func poll(now: Date = Date()) -> CodexPlanQuestionChanges {
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
            files[url.path] = FileSnapshot(modifiedAt: modifiedAt, questions: parse(url: url))
        }

        let unresolved = files.values.reduce(into: [String: CodexPlanQuestion]()) { result, file in
            result.merge(file.questions) { old, new in
                old.receivedAt >= new.receivedAt ? old : new
            }
        }
        let newActive = Set(unresolved.keys)
        let resolved = active.subtracting(newActive).filter { delivered.contains($0) }
        active = newActive

        // On launch, recover a question that was already on screen only when it
        // is fresh. This avoids resurrecting abandoned/rolled-back calls from
        // older tasks that never received a function_call_output record.
        if !hasPolled {
            let recoveryCutoff = startedAt.addingTimeInterval(-60)
            delivered.formUnion(unresolved.values
                .filter { $0.receivedAt < recoveryCutoff }
                .map(\.callID))
            hasPolled = true
        }

        let appeared = unresolved.values
            .filter { !delivered.contains($0.callID) }
            .sorted { $0.receivedAt < $1.receivedAt }
        delivered.formUnion(appeared.map(\.callID))

        return CodexPlanQuestionChanges(
            appeared: appeared,
            resolvedCallIDs: Array(resolved)
        )
    }

    private func recentRollouts(now: Date, manager: FileManager) -> [URL] {
        let calendar = Calendar(identifier: .gregorian)
        var result: [URL] = []

        // Yesterday is included so a question left open across midnight stays
        // visible; older unresolved calls are intentionally treated as stale.
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

    private func parse(url: URL) -> [String: CodexPlanQuestion] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return [:] }

        var sessionID = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var questions: [String: CodexPlanQuestion] = [:]
        var completed: Set<String> = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = root["payload"] as? [String: Any]
            else { continue }

            if root["type"] as? String == "session_meta" {
                sessionID = payload["id"] as? String ?? sessionID
                cwd = payload["cwd"] as? String ?? cwd
            } else if root["type"] as? String == "turn_context" {
                cwd = payload["cwd"] as? String ?? cwd
            }

            guard root["type"] as? String == "response_item",
                  let payloadType = payload["type"] as? String
            else { continue }

            if payloadType == "function_call_output", let callID = payload["call_id"] as? String {
                completed.insert(callID)
                continue
            }

            guard payloadType == "function_call",
                  payload["name"] as? String == "request_user_input",
                  let callID = payload["call_id"] as? String,
                  let arguments = payload["arguments"] as? String,
                  let argumentsData = arguments.data(using: .utf8),
                  let input = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any],
                  let rawQuestions = input["questions"] as? [[String: Any]]
            else { continue }

            let parsedQuestions = rawQuestions.compactMap(Self.parseQuestion)
            guard !parsedQuestions.isEmpty else { continue }
            let timestamp = (root["timestamp"] as? String).flatMap(Self.parseDate) ?? Date()
            questions[callID] = CodexPlanQuestion(
                callID: callID,
                sessionID: sessionID,
                cwd: cwd,
                questions: parsedQuestions,
                receivedAt: timestamp
            )
        }

        for callID in completed { questions.removeValue(forKey: callID) }
        return questions
    }

    private nonisolated static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private nonisolated static func parseQuestion(_ raw: [String: Any]) -> CodexQuestion? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let text = raw["question"] as? String, !text.isEmpty
        else { return nil }

        let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> CodexQuestionOption? in
            guard let label = option["label"] as? String, !label.isEmpty else { return nil }
            return CodexQuestionOption(
                label: label,
                detail: (option["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        guard !options.isEmpty else { return nil }
        return CodexQuestion(
            id: id,
            header: raw["header"] as? String ?? "Question",
            question: text,
            options: options,
            allowsOther: true
        )
    }
}
