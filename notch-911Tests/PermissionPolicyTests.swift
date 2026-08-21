import Foundation
import Testing
@testable import notch_911

@Suite("Permission policy decisions")
struct PermissionPolicyTests {

    // MARK: The master switch

    /// The switch is the whole safety story, so it is pinned first. With it off
    /// the app must behave exactly as it did before any of this existed: every
    /// permission asks.
    @Test("Nothing but Manual decides anything while the master switch is off",
          arguments: PermissionPolicy.allCases)
    func masterSwitchGatesEverything(_ policy: PermissionPolicy) {
        for tool in ["Edit", "Write", "Bash", "Read", "SomeToolNobodyHasHeardOf"] {
            #expect(policy.decision(forTool: tool, masterSwitch: false) == nil)
        }
    }

    @Test("Manual never decides, master switch or not")
    func manualAlwaysAsks() {
        for tool in ["Edit", "Bash", "Read"] {
            #expect(PermissionPolicy.manual.decision(forTool: tool, masterSwitch: true) == nil)
            #expect(PermissionPolicy.manual.decision(forTool: tool, masterSwitch: false) == nil)
        }
    }

    // MARK: The table

    @Test("Accept edits allows edit tools and asks about everything else")
    func acceptEdits() {
        let policy = PermissionPolicy.acceptEdits
        for tool in ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"] {
            #expect(policy.decision(forTool: tool, masterSwitch: true) == .allow)
        }
        for tool in ["Bash", "Read", "WebFetch", "Task"] {
            #expect(policy.decision(forTool: tool, masterSwitch: true) == nil)
        }
    }

    @Test("Auto allows anything it is allowed to answer at all")
    func auto() {
        let policy = PermissionPolicy.auto
        for tool in ["Edit", "Bash", "Read", "SomeToolNobodyHasHeardOf"] {
            #expect(policy.decision(forTool: tool, masterSwitch: true) == .allow)
        }
    }

    @Test("Plan allows reads and refuses everything else")
    func plan() {
        let policy = PermissionPolicy.plan
        for tool in ["Read", "Grep", "Glob", "WebFetch", "WebSearch"] {
            #expect(policy.decision(forTool: tool, masterSwitch: true) == .allow)
        }
        for tool in ["Edit", "Write", "Bash", "apply_patch"] {
            #expect(policy.decision(forTool: tool, masterSwitch: true) == .deny)
        }
    }

    /// The safe direction to be wrong in. A tool this app has never heard of is
    /// treated as mutating, so plan mode refuses it rather than waving it
    /// through on the strength of not recognising the name.
    @Test("An unknown tool is refused by Plan, not allowed")
    func unknownToolIsNotReadOnly() {
        #expect(PermissionPolicy.plan.decision(
            forTool: "SomeFutureMCPTool", masterSwitch: true) == .deny)
        #expect(PermissionPolicy.plan.decision(
            forTool: nil, masterSwitch: true) == .deny)
    }

    // MARK: The carve-out

    /// Both directions are bugs, and both are pinned. Auto-allowing
    /// `ExitPlanMode` approves a plan nobody read; auto-denying it under Plan
    /// wedges the session, because a refused `ExitPlanMode` is a session that
    /// can never leave plan mode.
    @Test("No policy ever answers ExitPlanMode or AskUserQuestion",
          arguments: PermissionPolicy.allCases)
    func neverAutoAnswered(_ policy: PermissionPolicy) {
        #expect(policy.decision(forTool: "ExitPlanMode", masterSwitch: true) == nil)
        #expect(policy.decision(forTool: "AskUserQuestion", masterSwitch: true) == nil)
    }

    // MARK: Seeding

    @Test("A session's observed mode seeds its policy")
    func seeding() {
        #expect(PermissionPolicy.seed(fromObservedMode: "acceptEdits") == .acceptEdits)
        #expect(PermissionPolicy.seed(fromObservedMode: "plan") == .plan)
        #expect(PermissionPolicy.seed(fromObservedMode: "default") == .manual)
        #expect(PermissionPolicy.seed(fromObservedMode: nil) == .manual)
        #expect(PermissionPolicy.seed(fromObservedMode: "somethingNew") == .manual)
    }

    /// Claude Code's own auto mode is a decision made inside that session. It
    /// must not silently arm this app's most dangerous setting.
    @Test("Claude Code's auto mode does not seed our Auto")
    func autoIsNeverInherited() {
        #expect(PermissionPolicy.seed(fromObservedMode: "auto") == .manual)
    }

    // MARK: Storage

    @Test("Pruning drops policies for sessions that are gone and keeps the rest")
    func pruning() {
        let live = "live-\(UUID().uuidString)"
        let dead = "dead-\(UUID().uuidString)"
        PolicyStore.set(.acceptEdits, for: live)
        PolicyStore.set(.auto, for: dead)

        PolicyStore.prune(keeping: [live])

        #expect(PolicyStore.policy(for: live) == .acceptEdits)
        #expect(PolicyStore.policy(for: dead) == nil)

        PolicyStore.prune(keeping: [])
        #expect(PolicyStore.policy(for: live) == nil)
    }
}
