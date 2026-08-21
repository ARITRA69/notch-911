//
//  PermissionPolicy.swift
//  notch-911
//
//  What the notch does with a session's `PermissionRequest` hooks before it
//  considers asking the user.
//
//  The name is borrowed from Claude Code's own permission modes, and the
//  borrowing stops there. Nothing in the hook schema can *set* a live session's
//  mode from outside — the hook is one-way, agent → notch → decision — so this
//  is not a remote control. It is this app's policy for answering the one thing
//  it genuinely owns: the request blocked on our socket.
//
//  That distinction is the whole design. A toggle that claimed to switch Claude
//  Code into acceptEdits would be lying; a toggle that auto-allows edit tools at
//  the choke point does exactly what the user wanted and can be checked.
//
//  Everything but `.manual` is gated on a master switch that ships off (§9 —
//  the reels precedent: gate the control *and* re-check at the point of use, so
//  a stale render can't act on a feature that has since been switched off).
//

import Foundation

nonisolated enum PermissionPolicy: String, Sendable, CaseIterable, Codable {
    /// Ask every time. What the app has always done, and the default for every
    /// session that hasn't been told otherwise.
    case manual
    /// Auto-allow the tools that edit a file that already exists, ask about
    /// everything else. Claude Code spells this `acceptEdits`.
    case acceptEdits
    /// Auto-allow everything this hook is asked about.
    case auto
    /// Auto-deny anything that would change the world, with a message telling
    /// the model to propose a plan instead. Read-only tools still pass.
    case plan

    /// What the control reads in the notch. Deliberately the user's words from
    /// the request rather than the wire names: "Manual" is clearer in a 600pt
    /// surface than "default".
    var title: String {
        switch self {
        case .manual: return "Manual"
        case .acceptEdits: return "Accept edits"
        case .auto: return "Auto"
        case .plan: return "Plan"
        }
    }

    /// One line under the control, so the user can tell what they are arming
    /// before they arm it.
    var detail: String {
        switch self {
        case .manual: return "Ask in the notch every time."
        case .acceptEdits: return "Allow file edits without asking. Ask about everything else."
        case .auto: return "Allow every tool call without asking, including shell commands."
        case .plan: return "Refuse anything that changes files, and ask for a plan instead."
        }
    }

    /// Whether arming this needs the master switch. `.manual` never does — it is
    /// the absence of a policy, not a policy.
    var needsMasterSwitch: Bool { self != .manual }

    /// The `permissionMode` strings Claude Code writes into its own transcript,
    /// mapped onto ours. Used once per session, to seed the policy from what the
    /// session was actually doing rather than from a guess — see
    /// `AgentSessionStore`.
    ///
    /// Anything unrecognised seeds `.manual`. A mode we don't understand is not
    /// a licence to stop asking.
    static func seed(fromObservedMode mode: String?) -> PermissionPolicy {
        switch mode {
        case "acceptEdits": return .acceptEdits
        case "plan": return .plan
        // Deliberately *not* mapped to `.auto`. Claude Code's own auto mode is
        // a decision the user made inside their session with its own confirms;
        // silently inheriting it here would arm this app's most dangerous
        // setting without anyone choosing it in this app. They can still pick
        // Auto by hand — it just doesn't happen behind their back.
        case "auto": return .manual
        default: return .manual
        }
    }
}

// MARK: - The decision

extension PermissionPolicy {

    /// Tools that edit a file that already exists, or create one in place.
    /// `MultiEdit` is legacy and costs nothing to keep; `apply_patch` is Codex's
    /// name for the same act, and is included so the control means the same
    /// thing on both agents.
    static let editTools: Set<String> = [
        "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch",
    ]

    /// Tools that only read. Everything *not* in here is treated as mutating by
    /// `.plan`, which is the safe direction to be wrong in: a new tool this app
    /// has never heard of gets refused during plan mode rather than waved
    /// through.
    static let readOnlyTools: Set<String> = [
        "Read", "Grep", "Glob", "WebFetch", "WebSearch",
        "NotebookRead", "TodoWrite", "ListMcpResources", "ReadMcpResource",
    ]

    /// Tools no policy may ever answer, whatever the user set.
    ///
    /// `AskUserQuestion` is a question addressed to the human. An app whose
    /// entire purpose is putting those in front of you must not be the thing
    /// that answers them.
    ///
    /// `ExitPlanMode` is worse in both directions. Auto-allowing it approves a
    /// plan — the single most considered decision in a session — without anyone
    /// reading it. Auto-denying it under `.plan` would wedge the session
    /// permanently: plan mode's only exit is the call being refused forever.
    /// Both are bugs, so the tool is simply out of scope for policy.
    static let neverAutoAnswered: Set<String> = ["ExitPlanMode", "AskUserQuestion"]

    /// The answer, or `nil` for "ask the user" — which is the only way the notch
    /// ever opens.
    ///
    /// `masterSwitch` is passed in rather than read from `UserDefaults` here so
    /// this stays a pure function: the whole decision table is testable without
    /// touching the defaults database or the main actor.
    func decision(forTool tool: String?, masterSwitch: Bool) -> PermissionDecision? {
        guard masterSwitch || !needsMasterSwitch else { return nil }
        if let tool, Self.neverAutoAnswered.contains(tool) { return nil }

        switch self {
        case .manual:
            return nil

        case .auto:
            return .allow

        case .acceptEdits:
            guard let tool, Self.editTools.contains(tool) else { return nil }
            return .allow

        case .plan:
            // An unknown tool is not read-only. See `readOnlyTools`.
            guard let tool, Self.readOnlyTools.contains(tool) else { return .deny }
            return .allow
        }
    }

    /// The reason that rides a `.plan` denial. Worded as an instruction rather
    /// than a refusal for the same reason `AskAnswer.denyMessage` is: a bare
    /// "denied" invites the model to try the identical call again.
    static let planDenyMessage =
        "The user has notch-911 holding this session in plan mode, so tools that change "
        + "anything are refused. Do not retry this call. Keep researching with read-only "
        + "tools, then propose a plan with ExitPlanMode."
}

// MARK: - Storage

/// Per-session policy, remembered across relaunches.
///
/// Keyed by session id: a policy is a statement about *this* piece of work, not
/// about the project or the agent. Two Claude Code sessions in the same checkout
/// — one refactoring, one reading — should not share an answer to "may this edit
/// files without asking".
///
/// Raw `UserDefaults` rather than `@AppStorage`, matching every other setting in
/// this app.
nonisolated enum PolicyStore {

    /// The one switch that arms every policy but `.manual`. Ships off.
    static let masterKey = "notchd.autoAnswer"

    private static let prefix = "notchd.policy."

    static func key(for sessionID: String) -> String { prefix + sessionID }

    static var masterSwitch: Bool {
        UserDefaults.standard.bool(forKey: masterKey)
    }

    static func policy(for sessionID: String) -> PermissionPolicy? {
        guard let raw = UserDefaults.standard.string(forKey: key(for: sessionID)) else {
            return nil
        }
        return PermissionPolicy(rawValue: raw)
    }

    static func set(_ policy: PermissionPolicy, for sessionID: String) {
        UserDefaults.standard.set(policy.rawValue, forKey: key(for: sessionID))
    }

    /// Drops the policies of sessions that are no longer around.
    ///
    /// Session ids are UUIDs and never repeat, so without this the defaults
    /// database grows by one key per session forever. Called with the ids the
    /// session store can still see; anything else goes.
    static func prune(keeping live: Set<String>) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let id = String(key.dropFirst(prefix.count))
            if !live.contains(id) { defaults.removeObject(forKey: key) }
        }
    }
}
