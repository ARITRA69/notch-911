//
//  CodexSettings.swift
//  notch-911
//
//  Codex support. PRD §5.3 deferred this to v2 on the grounds that Codex could
//  be detected but not answered — at the time its only signals were a
//  turn-completion `notify` hook and a one-way OSC 9 escape sequence.
//
//  That is no longer true. Codex CLI now ships a blocking `PermissionRequest`
//  hook returning the *same* `hookSpecificOutput.decision.behavior` shape as
//  Claude Code, so the whole keystroke-injection/Accessibility tradeoff in §5.3
//  evaporates and G5 survives intact.
//
//  The one wrinkle: Codex hook handlers are `command`-only — the config enum has
//  `command`, `prompt` and `agent` variants and no `http`. So instead of
//  pointing Codex at the server directly, we write a tiny shim per event that
//  relays stdin to the same loopback endpoint and echoes the decision back.
//
//  Codex has no `Elicitation` hook, so select/multi-select forms are Claude
//  Code only. `Stop` is the one place Codex can take free text back.
//

import Foundation

nonisolated enum CodexSettings {

    static let permissionPath = "/notchd/codex-permission"
    static let stopPath = "/notchd/codex-stop"

    private struct Registration {
        let event: String
        let path: String
        let shimName: String
        let statusMessage: String
    }

    private static let permission = Registration(
        event: "PermissionRequest",
        path: permissionPath,
        shimName: "codex-permission-hook.sh",
        statusMessage: "Waiting for you in the notch…"
    )

    private static let stop = Registration(
        event: "Stop",
        path: stopPath,
        shimName: "codex-stop-hook.sh",
        statusMessage: "Anything else? Check the notch…"
    )

    enum CodexError: Error, LocalizedError {
        case malformed
        case unwritable(Error)

        var errorDescription: String? {
            switch self {
            case .malformed:
                return "~/.codex/hooks.json is not a JSON object. Paste the hook block in manually."
            case .unwritable(let underlying):
                return "Could not write the Codex hook: \(underlying.localizedDescription)"
            }
        }
    }

    static var hooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    /// The shims live in Application Support rather than inside the app bundle:
    /// the bundle path moves between DerivedData and /Applications, and a stale
    /// absolute path in hooks.json would be a silent no-op.
    private static var shimDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("notch-911", isDirectory: true)
    }

    /// True when Codex is actually installed. No point offering to connect
    /// something that isn't there.
    static func isCodexInstalled() -> Bool {
        FileManager.default.fileExists(atPath: hooksURL.deletingLastPathComponent().path)
    }

    static func isConnected() -> Bool {
        guard let root = try? read(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains(where: isOurs) == true
        }
    }

    // MARK: Mutation

    static func connect(port: UInt16, token: String, includeStop: Bool) throws {
        var registrations = [permission]
        if includeStop { registrations.append(stop) }

        for registration in registrations {
            try writeShim(registration, port: port, token: token)
        }
        if !includeStop {
            try? FileManager.default.removeItem(at: shimDirectory.appendingPathComponent(stop.shimName))
        }

        var root = try read()
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for key in hooks.keys {
            guard var groups = hooks[key] as? [[String: Any]] else { continue }
            groups.removeAll(where: isOurs)
            if groups.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = groups }
        }

        for registration in registrations {
            var groups = hooks[registration.event] as? [[String: Any]] ?? []
            groups.append(hookGroup(registration))
            hooks[registration.event] = groups
        }

        root["hooks"] = hooks
        try write(root)
    }

    static func disconnect() throws {
        var root = try read()
        if var hooks = root["hooks"] as? [String: Any] {
            for key in hooks.keys {
                guard var groups = hooks[key] as? [[String: Any]] else { continue }
                groups.removeAll(where: isOurs)
                if groups.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = groups }
            }
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }
            try write(root)
        }
        for registration in [permission, stop] {
            try? FileManager.default.removeItem(
                at: shimDirectory.appendingPathComponent(registration.shimName)
            )
        }
    }

    static func manualSnippet() -> String {
        let block: [String: Any] = ["hooks": [permission.event: [hookGroup(permission)]]]
        guard let data = try? JSONSerialization.data(
            withJSONObject: block,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Shim

    /// Relays the hook payload from stdin to the loopback server and echoes the
    /// decision back on stdout.
    ///
    /// The exit-code discipline here is load-bearing. Codex reads **exit code 2
    /// as a denial**, so any failure path that exits 2 would turn a crashed or
    /// quit app into a tool-call blocker — precisely the §11 rule that the app
    /// being broken must never be worse than the app not being installed.
    /// Every path therefore exits 0, and an empty stdout means "no decision",
    /// which drops the user back into Codex's own approval prompt.
    private static func writeShim(_ registration: Registration, port: UInt16, token: String) throws {
        let quotedToken = token.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        # Generated by notch-911 for the Codex \(registration.event) hook.
        # Codex hook handlers are command-only, so this bridges
        # stdin -> loopback HTTP -> stdout.
        #
        # Never exit 2: Codex reads exit code 2 as "deny". Failing open means
        # exiting 0 with no stdout, which falls through to Codex's own prompt.
        RESPONSE=$(/usr/bin/curl -sS -m 600 \\
          -H 'Authorization: Bearer \(quotedToken)' \\
          -H 'Content-Type: application/json' \\
          --data-binary @- \\
          'http://127.0.0.1:\(port)\(registration.path)' 2>/dev/null) || exit 0
        printf '%s' "$RESPONSE"
        exit 0

        """

        do {
            let manager = FileManager.default
            try manager.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
            let destination = shimDirectory.appendingPathComponent(registration.shimName)
            try Data(script.utf8).write(to: destination, options: .atomic)
            // Owner-only: the file carries the bearer token.
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        } catch {
            throw CodexError.unwritable(error)
        }
    }

    // MARK: Private

    private static func hookGroup(_ registration: Registration) -> [String: Any] {
        [
            // A real regex, unlike Claude Code's documented "*" shorthand —
            // Codex's own examples use anchored patterns like "^Bash$".
            "matcher": ".*",
            "hooks": [[
                "type": "command",
                "command": shimDirectory.appendingPathComponent(registration.shimName).path,
                "timeout": 600,
                "statusMessage": registration.statusMessage,
            ]],
        ]
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { entry in
            guard let command = entry["command"] as? String else { return false }
            return command.hasSuffix(permission.shimName) || command.hasSuffix(stop.shimName)
        }
    }

    private static func read() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: hooksURL), !data.isEmpty else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexError.malformed
        }
        return root
    }

    private static func write(_ root: [String: Any]) throws {
        do {
            let manager = FileManager.default
            try manager.createDirectory(
                at: hooksURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            backup()
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: hooksURL, options: .atomic)
        } catch {
            throw CodexError.unwritable(error)
        }
    }

    private static func backup() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: hooksURL.path) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = hooksURL.deletingLastPathComponent()
            .appendingPathComponent("hooks.json.notchd-backup-\(formatter.string(from: Date()))")
        try? manager.copyItem(at: hooksURL, to: destination)
    }
}
