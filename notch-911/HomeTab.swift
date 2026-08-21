//
//  HomeTab.swift
//  notch-911
//
//  What a click on the notch lands on.
//
//  0.8.0 landed on Agents, which is the wrong surface to arrive at: it is where
//  you *configure* a session — the full list, each row opening onto a cwd and a
//  four-way permission mode. The question you actually open the notch to answer
//  is "is anything waiting on me, and is anything moving?", and answering it
//  meant scanning a list built for a different job.
//
//  So Home is triage and Agents stays configuration. Counters across the top,
//  then the one list that matters: everything blocked, then everything running.
//  Idle sessions are a number here and rows one tab to the right — a surface
//  hanging off a notch gets about a second of attention, and spending it on
//  sessions that are not doing anything is spending it badly.
//
//  Read-only, apart from Resume. That restraint is the whole reason the two tabs
//  are different tabs: put a mode control on Home and it becomes Agents.
//

import SwiftUI

struct HomeTab: View {
    let coordinator: PromptCoordinator
    let sessions: AgentSessionStore

    /// Matches the Agents tab's cap. Four tiles and a footer sit above it, and
    /// the panel's usable height is fixed.
    private static let listHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            stats
            list
            notchFooterHint("⎋ close")
        }
    }

    // MARK: Counters

    private var stats: some View {
        HStack(spacing: 6) {
            NotchStat(
                value: waiting.count,
                label: "waiting",
                tint: waiting.isEmpty ? nil : .orange.opacity(0.9)
            )
            NotchStat(
                value: running.count,
                label: "running",
                tint: running.isEmpty ? nil : .green.opacity(0.85)
            )
            NotchStat(value: idleCount, label: "idle")
            // Hidden at zero on purpose: it reads zero for everyone who has
            // never armed the master switch, and a counter that is always zero
            // teaches people to stop looking at the row it sits in.
            if answered > 0 {
                NotchStat(value: answered, label: "answered")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: The list

    @ViewBuilder
    private var list: some View {
        if waiting.isEmpty && running.isEmpty {
            empty
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    // Blocked first, always. It is the only genuinely actionable
                    // thing in the notch.
                    ForEach(waiting) { prompt in
                        StrandedRow(prompt: prompt) { coordinator.resurface(prompt) }
                    }
                    ForEach(running) { session in
                        runningRow(session)
                    }
                }
            }
            .frame(maxHeight: Self.listHeight)
            .scrollIndicators(.never)
        }
    }

    private func runningRow(_ session: AgentSession) -> some View {
        // Tapping goes to Agents rather than expanding here: the thing you want
        // after looking at a running session is its mode, and that control lives
        // one tab over. Two places to set it would be one too many.
        NotchRow { coordinator.selectTab(.agents) } content: {
            HStack(spacing: 8) {
                BrandMark(session.agent.logoAsset, size: 11)
                    .foregroundStyle(.white.opacity(0.75))
                    .opacity(0.75)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(session.projectName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                        if let branch = session.gitBranch {
                            Text(branch)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(NotchInk.tertiary))
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(.green.opacity(0.8))
                            .frame(width: 5, height: 5)
                        Text("running")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(NotchInk.tertiary))
                    }
                }
                Spacer(minLength: 6)
                Text(NotchTime.relative(session.lastActivity))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(NotchInk.hint))
            }
        }
        .accessibilityLabel("\(session.projectName), running")
    }

    // MARK: Nothing to show

    /// Three shades of empty. The last one matters most: with app health
    /// deliberately out of scope for this tab, a disconnected agent is the whole
    /// explanation for a screen of zeros, and leaving it unsaid would make a
    /// working app look broken.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sessions.hasScanned
                 ? "Nothing waiting. No sessions in the last day."
                 : "Nothing waiting.")
                .font(.caption)
                .foregroundStyle(.white.opacity(NotchInk.tertiary))
                .fixedSize(horizontal: false, vertical: true)

            if !anyConnector {
                Text("Claude Code and Codex aren't connected — wire them up in the status window.")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Derived

    /// Just `stranded`, not `stranded` plus `current`. A prompt always preempts
    /// the idle surface, so the tabs are never on screen while one is up —
    /// adding it would be arithmetic for a case that cannot happen.
    private var waiting: [Prompt] { coordinator.stranded }

    private var running: [AgentSession] {
        sessions.sessions.filter { $0.state == .running }
    }

    private var idleCount: Int {
        sessions.sessions.count { $0.state == .idle }
    }

    private var answered: Int {
        sessions.sessions.reduce(0) { $0 + $1.autoAnswered }
    }

    private var anyConnector: Bool {
        coordinator.agentStatus.claudeConnected || coordinator.agentStatus.codexConnected
    }
}
