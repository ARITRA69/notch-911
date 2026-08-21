//
//  TabsCard.swift
//  notch-911
//
//  The surface a click on the notch opens: Agents, Media, Tools.
//
//  Why a second hub at all, when the peek already exists — the peek is a
//  *glance*. It opens on hover, it may never take the keyboard, and its header
//  chip row is out of room: the comment on `PeekCard.clipboardChip` records
//  that chips beat columns there only because 540pt minus the shelf's fixed
//  136pt left nothing to spend. Everything this app has grown since has had to
//  fit in that row as one more 20pt glyph.
//
//  So the peek stays exactly as it was, and a click — which used to mean
//  nothing unless a note was recording — opens somewhere you can actually look
//  around. Hover to glance, click to browse.
//
//  The tabs are launchers, not reimplementations. Media and Tools drill into
//  the surfaces that already exist through the coordinator's own `openX()`
//  methods; nothing here re-renders the clipboard or the mirror.
//

import SwiftUI

nonisolated enum NotchTab: String, CaseIterable, Identifiable, Sendable {
    case agents
    case media
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: return "Agents"
        case .media: return "Media"
        case .tools: return "Tools"
        }
    }

    /// Matching `StatusView.Tab`, which is the house pattern for this.
    var symbol: String {
        switch self {
        case .agents: return "sparkles"
        case .media: return "play.circle"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

struct TabsCard: View {
    let coordinator: PromptCoordinator
    let sessions: AgentSessionStore
    let media: MediaMonitor
    let shelf: ShelfStore
    let clipboard: ClipboardStore
    let voice: VoiceNoteStore

    /// Which session row is expanded. One at a time: the policy control is four
    /// wide, and two open rows would push the third off a surface that cannot
    /// grow past the panel.
    @State private var expanded: String?

    /// Set the first time Auto is picked on any session, and reset when the
    /// surface goes away. Arming the one policy that waves through `Bash` should
    /// cost a deliberate second click — see `PermissionPolicy`.
    @State private var confirmingAuto: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tabBar
            Group {
                switch coordinator.selectedTab {
                case .agents: agentsTab
                case .media: mediaTab
                case .tools: toolsTab
                }
            }
            // Without this the surface jumps its full height mid-swap while the
            // outgoing tab is still mounted. `CardHeightKey` measures whatever
            // is here, so the container follows it either way — this only stops
            // the measurement itself flickering.
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.16), value: coordinator.selectedTab)
        .background(shortcuts)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(NotchTab.allCases) { tab in
                NotchChip(isSelected: coordinator.selectedTab == tab) {
                    coordinator.selectTab(tab)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                        Text(tab.title)
                    }
                }
                .accessibilityLabel(tab.title)
            }
            Spacer(minLength: 0)
            if !coordinator.stranded.isEmpty {
                Text("\(coordinator.stranded.count) waiting")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(NotchInk.tertiary))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.white.opacity(NotchInk.fill), in: Capsule())
            }
            Button { coordinator.closeTabs() } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(NotchInk.tertiary))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: Agents

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConnectorRow(status: coordinator.agentStatus)

            if sessions.sessions.isEmpty {
                Text(sessions.hasScanned
                     ? "No sessions in the last day."
                     : "Looking for sessions…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(NotchInk.tertiary))
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(sessions.sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
                .frame(maxHeight: 320)
                .scrollIndicators(.never)
            }

            if !PolicyStore.masterSwitch {
                notchFooterHint("Modes other than Manual need Auto-answer on, in the status window.")
            } else {
                notchFooterHint("⎋ close")
            }
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        let isOpen = expanded == session.id
        return NotchRow(isSelected: isOpen) {
            expanded = isOpen ? nil : session.id
            confirmingAuto = nil
        } content: {
            VStack(alignment: .leading, spacing: isOpen ? 8 : 0) {
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
                            stateDot(session.state)
                            Text(stateLabel(session))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(NotchInk.tertiary))
                        }
                    }

                    Spacer(minLength: 6)

                    Text(policy(for: session).title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(isOpen ? 0.75 : NotchInk.tertiary))
                    Text(NotchTime.relative(session.lastActivity))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(NotchInk.hint))
                }

                if isOpen { expandedDetail(session) }
            }
        }
        .accessibilityLabel("\(session.projectName), \(stateLabel(session))")
    }

    @ViewBuilder
    private func expandedDetail(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.cwd)
                .font(.caption2.monospaced())
                .foregroundStyle(.white.opacity(NotchInk.hint))
                .lineLimit(1)
                .truncationMode(.head)

            HStack(spacing: 5) {
                ForEach(PermissionPolicy.allCases, id: \.self) { option in
                    NotchChip(isSelected: policy(for: session) == option) {
                        choose(option, for: session)
                    } label: {
                        Text(option.title)
                    }
                    .accessibilityLabel("\(option.title) for \(session.projectName)")
                }
                Spacer(minLength: 0)
                if let prompt = blockedPrompt(for: session) {
                    Button { coordinator.resurface(prompt) } label: {
                        Text("Resume")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Resume \(session.projectName)")
                }
            }

            if confirmingAuto == session.id {
                Text("Auto allows every tool call in this session, shell commands included, "
                     + "without showing you anything. Tap Auto again to turn it on.")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(policy(for: session).detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(NotchInk.hint))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if session.autoAnswered > 0 {
                Text("\(session.autoAnswered) answered without asking")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(NotchInk.hint))
            }
        }
    }

    private func stateDot(_ state: AgentSession.State) -> some View {
        Circle()
            .fill(color(for: state))
            .frame(width: 5, height: 5)
    }

    private func color(for state: AgentSession.State) -> Color {
        switch state {
        case .waiting: return .orange.opacity(0.9)
        case .running: return .green.opacity(0.8)
        case .idle: return .white.opacity(0.2)
        }
    }

    private func stateLabel(_ session: AgentSession) -> String {
        switch session.state {
        case .waiting: return "waiting on you"
        case .running: return "running"
        case .idle: return "idle"
        }
    }

    private func policy(for session: AgentSession) -> PermissionPolicy {
        coordinator.policy(for: session.id, observedMode: session.observedMode)
    }

    private func blockedPrompt(for session: AgentSession) -> Prompt? {
        coordinator.stranded.first { $0.sessionId == session.id }
    }

    /// Auto is the one option that asks twice. Everything else applies on the
    /// first click.
    private func choose(_ option: PermissionPolicy, for session: AgentSession) {
        guard option == .auto, policy(for: session) != .auto else {
            confirmingAuto = nil
            coordinator.setPolicy(option, for: session.id)
            return
        }
        guard confirmingAuto == session.id else {
            confirmingAuto = session.id
            return
        }
        confirmingAuto = nil
        coordinator.setPolicy(option, for: session.id)
    }

    // MARK: Media

    private var mediaTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let track = media.nowPlaying {
                HStack(alignment: .top, spacing: 12) {
                    NowPlayingCover(media: media, size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            if let logo = track.source.logoAsset {
                                BrandMark(logo, size: 11)
                            } else {
                                Image(systemName: "music.note")
                            }
                            Text(track.source.displayName)
                            Spacer(minLength: 4)
                            Text(NotchTime.label(track)).monospacedDigit()
                        }
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))

                        Text(track.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.white.opacity(NotchInk.primary))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)

                        NowPlayingProgress(track: track).padding(.top, 4)
                        NowPlayingTransport(media: media, track: track, width: 96)
                            .padding(.top, 2)
                    }
                }
            } else {
                Text(mediaEmptyMessage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(NotchInk.tertiary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            launcher(
                glyph: "person.crop.square",
                title: "Mirror",
                detail: "The camera, as a 9:16 mirror."
            ) { coordinator.openMirror() }

            if coordinator.reelsEnabled {
                launcher(
                    glyph: "play.rectangle.on.rectangle",
                    title: "Reels",
                    detail: "Instagram, while an agent works."
                ) { coordinator.openReels() }
            }

            notchFooterHint("⎋ close")
        }
    }

    private var mediaEmptyMessage: String {
        if media.isPermissionDenied {
            return "Allow notch-911 in System Settings → Privacy & Security → Automation to show what's playing."
        }
        if media.needsBrowserJavaScript {
            return "YouTube Music is open. Turn on Develop → Allow JavaScript from Apple Events in that browser to read it."
        }
        return "Nothing playing."
    }

    // MARK: Tools

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 4) {
                    launcher(
                        glyph: clipboard.items.isEmpty ? "doc.on.clipboard" : "doc.on.clipboard.fill",
                        title: "Clipboard",
                        detail: clipboard.items.isEmpty
                            ? "The last 30 things you copied."
                            : "\(clipboard.items.count) held · ⇧⌘V",
                        shortcut: "⇧⌘V"
                    ) { coordinator.openClipboard() }

                    launcher(
                        glyph: "mic",
                        title: "Voice notes",
                        detail: voice.notes.isEmpty
                            ? "Talk, and it lands here as text."
                            : "\(voice.notes.count) saved",
                        shortcut: "⇧⌘M"
                    ) { coordinator.openVoice() }

                    launcher(
                        glyph: "gamecontroller",
                        title: "Snake",
                        detail: "For the twenty minutes an agent spends working."
                    ) { coordinator.openGame() }
                }

                // The shelf is a drop target that needs area, so it gets drawn
                // rather than launched into. It has no surface of its own to
                // open — in the peek it is a column, and here it is the same
                // column with room to breathe.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shelf")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(NotchInk.tertiary))
                    ShelfView(store: shelf) { _ in }
                }
            }
            notchFooterHint("⎋ close")
        }
    }

    // MARK: Shared row

    private func launcher(
        glyph: String,
        title: String,
        detail: String,
        shortcut: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        NotchRow(action: action) {
            HStack(spacing: 9) {
                Image(systemName: glyph)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(NotchInk.tertiary))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let shortcut {
                    Text(shortcut)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(NotchInk.hint))
                }
            }
        }
        .accessibilityLabel(title)
    }

    // MARK: Keyboard

    /// Same trick as `ClipboardCard.shortcuts`: zero-size buttons behind the
    /// card, which works only because this surface makes the panel key.
    ///
    /// `[` and `]` move between tabs. Not ⌘1…⌘3 — those belong to the numbered
    /// choices on a prompt card, and a user who has learned them there should
    /// not find them meaning something else one surface over.
    private var shortcuts: some View {
        ZStack {
            Button("") { coordinator.closeTabs() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("") { cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [])
            Button("") { cycleTab(1) }
                .keyboardShortcut("]", modifiers: [])
            Button("") { cycleTab(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { cycleTab(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func cycleTab(_ delta: Int) {
        let all = NotchTab.allCases
        guard let index = all.firstIndex(of: coordinator.selectedTab) else { return }
        // Clamped rather than wrapped, matching the clipboard's arrow keys.
        let next = min(max(index + delta, 0), all.count - 1)
        coordinator.selectTab(all[next])
    }
}
