//
//  ClaudeSettings.swift
//  notch-911
//
//  Reads, merges and un-merges our hook entries in ~/.claude/settings.json.
//
//  Merge, never overwrite (§9). Every write is preceded by a timestamped backup,
//  and the file's 0600 mode is restored afterwards — atomic writes replace the
//  inode and would otherwise leave it world-readable.
//

import Foundation

nonisolated enum ClaudeSettings {

    // Distinctive paths so our entries can be found and removed again without
    // guessing at ports or tokens.
    static let permissionPath = "/notchd/permission"
    static let elicitationPath = "/notchd/elicitation"
    static let stopPath = "/notchd/stop"

    /// Everything we own lives under this prefix.
    private static let marker = "/notchd/"

    private struct Registration {
        let event: String
        let path: String
        let statusMessage: String
    }

    enum SettingsError: Error, LocalizedError {
        case malformed
        case unwritable(Error)

        var errorDescription: String? {
            switch self {
            case .malformed:
                return "~/.claude/settings.json is not a JSON object. Paste the hook block in manually."
            case .unwritable(let underlying):
                return "Could not write ~/.claude/settings.json: \(underlying.localizedDescription)"
            }
        }
    }

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    static func endpoint(port: UInt16, path: String) -> String {
        "http://127.0.0.1:\(port)\(path)"
    }

    // MARK: Status

    static func isConnected() -> Bool {
        guard let root = try? read(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains(where: isOurs) == true
        }
    }

    // MARK: Mutation

    /// Adds (or updates in place) our hook entries.
    ///
    /// Safe to call on every launch — that is in fact how the port stays correct,
    /// since it changes whenever the preferred range is contended.
    ///
    /// `includeStop` is off by default per §13 open question 1: Stop fires on
    /// *every* turn end, which would be a lot of notch.
    static func connect(port: UInt16, token: String, includeStop: Bool) throws {
        var registrations = [
            Registration(event: "PermissionRequest", path: permissionPath,
                         statusMessage: "Waiting for you in the notch…"),
            Registration(event: "Elicitation", path: elicitationPath,
                         statusMessage: "Waiting for your input in the notch…"),
        ]
        if includeStop {
            registrations.append(
                Registration(event: "Stop", path: stopPath,
                             statusMessage: "Anything else? Check the notch…")
            )
        }

        var root = try read()
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        // Drop every entry of ours first, so turning Stop off actually removes it.
        for key in hooks.keys {
            guard var groups = hooks[key] as? [[String: Any]] else { continue }
            groups.removeAll(where: isOurs)
            if groups.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = groups }
        }

        for registration in registrations {
            var groups = hooks[registration.event] as? [[String: Any]] ?? []
            groups.append(hookGroup(port: port, token: token, registration: registration))
            hooks[registration.event] = groups
        }

        root["hooks"] = hooks
        try write(root)
    }

    /// Removes our entries and any now-empty containers we created.
    static func disconnect() throws {
        var root = try read()
        guard var hooks = root["hooks"] as? [String: Any] else { return }

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

    /// The block to paste by hand when the file is malformed or unwritable (§9).
    static func manualSnippet(port: UInt16, token: String) -> String {
        let registration = Registration(event: "PermissionRequest", path: permissionPath,
                                        statusMessage: "Waiting for you in the notch…")
        let block: [String: Any] = [
            "hooks": ["PermissionRequest": [hookGroup(port: port, token: token, registration: registration)]]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: block,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Private

    private static func hookGroup(
        port: UInt16,
        token: String,
        registration: Registration
    ) -> [String: Any] {
        [
            "matcher": "*",
            "hooks": [[
                "type": "http",
                "url": endpoint(port: port, path: registration.path),
                // §5.2 — the documented maximum, treated as the user's
                // think-time ceiling rather than a network timeout.
                "timeout": 600,
                "headers": ["Authorization": "Bearer \(token)"],
                "statusMessage": registration.statusMessage,
            ]],
        ]
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["url"] as? String)?.contains(marker) == true }
    }

    private static func read() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsError.malformed
        }
        return root
    }

    private static func write(_ root: [String: Any]) throws {
        do {
            let manager = FileManager.default
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            backup()

            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: .atomic)
            // .atomic swaps in a fresh inode with default (0644) permissions.
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as SettingsError {
            throw error
        } catch {
            throw SettingsError.unwritable(error)
        }
    }

    private static func backup() {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return }
        // Built per call rather than cached: DateFormatter isn't Sendable, and
        // this runs at most once per connect.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"   // colon-free, reads sanely in Finder
        let stamp = formatter.string(from: Date())
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("settings.json.notchd-backup-\(stamp)")
        try? manager.copyItem(at: url, to: destination)
    }
}
