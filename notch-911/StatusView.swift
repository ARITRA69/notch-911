//
//  StatusView.swift
//  notch-911
//
//  The app's only window: is the server up, which hooks are registered,
//  and what has come through.
//

import SwiftUI

struct StatusView: View {
    @Bindable var model: AppModel

    /// Three panes rather than one long column. The window used to be a fixed
    /// 580×640 with everything stacked inside it, which meant the event log was
    /// clipped off the bottom with no way to reach it — and the clipboard had
    /// nowhere to live at all beyond a count.
    enum Tab: String, CaseIterable, Identifiable {
        case status = "Status"
        case clipboard = "Clipboard"
        case voice = "Voice"
        case events = "Events"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .status: "gearshape"
            case .clipboard: "doc.on.clipboard"
            case .voice: "waveform"
            case .events: "list.bullet.rectangle"
            }
        }
    }

    @State private var tab: Tab = .status

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tabPicker

            // Each pane scrolls on its own. The log and the clipboard both grow
            // without bound, so a single outer scroller would leave you hunting
            // for the settings under a thousand events.
            ScrollView {
                Group {
                    switch tab {
                    case .status: statusTab
                    case .clipboard: clipboardTab
                    case .voice: voiceTab
                    case .events: eventsTab
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(22)
        // Was a hard `width:height:`, which is what made the content unreachable.
        // A minimum plus an ideal lets the window open at the old size and be
        // dragged bigger when a pane has more in it.
        .frame(minWidth: 560, idealWidth: 600, minHeight: 480, idealHeight: 680,
               alignment: .topLeading)
        .background(.background)
    }

    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(Tab.allCases) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Tabs

    private var statusTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            card {
                serverRow
                rowDivider
                hookRow
                if model.isCodexInstalled {
                    rowDivider
                    codexRow
                    rowDivider
                    accessibilityRow
                }
            }

            if let error = model.setupError { errorBox(error) }

            card {
                autoAnswerRow
                Divider().padding(.leading, 14)
                stopRow
                Divider().padding(.leading, 14)
                youTubeMusicRow
                Divider().padding(.leading, 14)
                clipboardRow
                Divider().padding(.leading, 14)
                clipboardStorageRow
                Divider().padding(.leading, 14)
                voiceRow
                Divider().padding(.leading, 14)
                reelsRow
                Divider().padding(.leading, 14)
                reelsStorageRow
            }
        }
    }

    private var eventsTab: some View { logSection }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            // The real app icon, not a drawn stand-in. A macOS icon carries its
            // own margin inside the canvas, so 46pt lands at the visual weight
            // the old 40pt tile had.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text("notch-911")
                    .font(.title3.weight(.semibold))
                Text("Agent prompts — permission, selects and free text — answered from the notch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            updateButton
        }
    }

    /// Icon only; the tooltip carries the whole story. One control does both
    /// jobs — it runs the check, and once something turns up it opens the
    /// release page, so a found update is never stranded in the app menu.
    private var updateButton: some View {
        let checker = UpdateChecker.shared
        return Button {
            if let update = checker.available {
                checker.open(update)
            } else {
                checker.checkNow()
            }
        } label: {
            Group {
                if checker.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: updateSymbol)
                        .imageScale(.large)
                        .foregroundStyle(updateTint)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(updateTooltip)
        .animation(.easeInOut(duration: 0.15), value: checker.isChecking)
        .animation(.easeInOut(duration: 0.15), value: updateSymbol)
    }

    private var updateSymbol: String {
        let checker = UpdateChecker.shared
        if checker.available != nil { return "arrow.down.circle.fill" }
        switch checker.lastOutcome {
        case .upToDate: return "checkmark.circle.fill"
        case .unreachable: return "exclamationmark.triangle.fill"
        case nil: return "arrow.clockwise"
        }
    }

    private var updateTint: Color {
        let checker = UpdateChecker.shared
        if checker.available != nil { return .accentColor }
        switch checker.lastOutcome {
        case .upToDate: return .green
        case .unreachable: return .orange
        case nil: return .secondary
        }
    }

    private var updateTooltip: String {
        let checker = UpdateChecker.shared
        if let update = checker.available {
            return "Version \(update.version) is available — open the release page"
        }
        if checker.isChecking { return "Checking for updates…" }
        switch checker.lastOutcome {
        case .upToDate: return "Up to date (v\(UpdateChecker.currentVersion))"
        case .unreachable: return "Couldn't reach GitHub — click to try again"
        case nil: return "Check for updates (v\(UpdateChecker.currentVersion))"
        }
    }

    // MARK: - Rows

    private var serverRow: some View {
        row(color: serverColor, title: "Local hook server", detail: serverDescription, mono: true) {
            Menu {
                ForEach(AppModel.SimulatedShape.allCases) { shape in
                    Button(shape.rawValue) { model.simulate(shape) }
                }
            } label: {
                Label("Simulate", systemImage: "play.fill")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .disabled(model.port == nil)
        }
    }

    private var hookRow: some View {
        row(
            color: model.isConnected ? .green : .secondary,
            title: "Claude Code hook",
            detail: model.isConnected
                ? "PermissionRequest + Elicitation\(model.surfaceStop ? " + Stop" : "") in ~/.claude/settings.json"
                : "Not registered",
            logo: Agent.claudeCode.logoAsset
        ) {
            if model.isConnected {
                Button("Disconnect") { model.disconnect() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Connect") { model.connect() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.port == nil)
            }
        }
    }

    private var codexRow: some View {
        row(
            color: model.isCodexConnected ? .green : .secondary,
            title: "Codex hook",
            detail: model.isCodexConnected
                ? "Permissions via hook · plan questions via local task watcher"
                : "Plan questions watched locally · permission hook not registered",
            logo: Agent.codex.logoAsset
        ) {
            Button {
                model.simulate(.permission, agent: .codex)
            } label: {
                Label("Simulate", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.port == nil)

            if model.isCodexConnected {
                Button("Disconnect") { model.disconnectCodex() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Connect") { model.connectCodex() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.port == nil)
            }
        }
    }

    private var accessibilityRow: some View {
        row(
            color: model.accessibilityTrusted ? .green : .orange,
            title: "Direct Codex answers",
            detail: accessibilityDetail,
            logo: Agent.codex.logoAsset
        ) {
            if !model.accessibilityTrusted {
                Button("Enable") { model.enableAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private var accessibilityDetail: String {
        if model.accessibilityTrusted {
            return "Accessibility enabled · \(model.signatureStatus.detail)"
        }
        if model.signatureStatus.isStable {
            return "Accessibility required once · \(model.signatureStatus.detail)"
        }
        return model.signatureStatus.detail
    }

    private var stopRow: some View {
        toggleRow(
            isOn: $model.surfaceStop,
            title: "Surface Stop events",
            detail: "Ask \"anything else?\" at the end of every turn. Off by default — it fires a lot."
        )
    }

    private var youTubeMusicRow: some View {
        toggleRow(
            isOn: $model.youTubeMusic,
            title: "YouTube Music in the mini player",
            detail: "Spotify and Music work out of the box. YouTube Music lives in a browser tab, "
                + "so this needs Automation access for that browser plus "
                + "Develop → Allow JavaScript from Apple Events."
        )
    }

    private var clipboardRow: some View {
        toggleRow(
            isOn: $model.clipboardCapture,
            title: "Clipboard history",
            detail: "Keeps the last \(ClipboardStore.maxItems) things you copied, in the notch. "
                + "Nothing leaves this Mac, and anything an app marks confidential — "
                + "password managers do — is never captured."
        )
    }

    /// The clear button lives in its own row rather than inside `toggleRow`:
    /// `.toggleStyle(.switch)` puts the switch on the trailing edge of its own
    /// frame, so squeezing a button in beside it strands the switch mid-row.
    /// This also gives the hotkey somewhere to report from — a chord another app
    /// already owns registers successfully and then never fires, so "it's on" is
    /// worth stating rather than assuming.
    /// The switch that makes the notch's per-session modes do anything.
    ///
    /// First in the card because it is the one setting here that can cause the
    /// app to act *instead of* asking — everything else below it changes what
    /// gets shown.
    private var autoAnswerRow: some View {
        toggleRow(
            isOn: $model.autoAnswer,
            title: "Auto-answer by session mode",
            detail: "Lets the per-session mode in the notch's Agents tab answer permission "
                + "requests for you: Accept edits allows file edits, Auto allows every tool "
                + "call including shell commands, Plan refuses anything that changes files. "
                + "Sessions left on Manual always ask, and plan approvals and questions for "
                + "you are never answered automatically. Every automatic answer is listed "
                + "under Events."
        )
    }

    private var reelsRow: some View {
        toggleRow(
            isOn: $model.reels,
            title: "Reels in the notch",
            detail: "Scroll Instagram while an agent works; a prompt takes the notch back the "
                + "moment one arrives. Signs into Instagram in a web view and keeps that "
                + "session on this Mac. Passwords go straight to the page — paste with ⌘V, "
                + "since a web view has no password-manager autofill."
        )
    }

    private var reelsStorageRow: some View {
        row(
            color: .pink,
            title: "Instagram session",
            detail: "Stored on this Mac until you sign out. Turning the switch off hides the "
                + "surface but keeps you logged in."
        ) {
            Button("Sign out") { model.signOutOfReels() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var clipboardStorageRow: some View {
        row(
            color: clipboardColor,
            title: "Stored clippings",
            detail: model.isClipboardHotkeyRegistered
                ? "\(model.clipboard.items.count) stored · ⇧⌘V opens the notch"
                : "⇧⌘V could not be registered — another app may own it. "
                    + "The clipboard button in the notch peek always works."
        ) {
            Button("Clear") { model.clearClipboardHistory() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.clipboard.items.isEmpty)
        }
    }

    private var clipboardColor: Color {
        guard model.clipboardCapture else { return .secondary }
        return model.isClipboardHotkeyRegistered ? .green : .orange
    }

    /// Mirrors `accessibilityRow`: a permission that might still need a visit
    /// to System Settings, stated plainly rather than discovered by pressing
    /// the hotkey and getting silence. Recording works with the microphone
    /// alone — a denied speech permission still shows green, since it only
    /// costs the transcript, not the note.
    private var voiceRow: some View {
        row(color: voiceColor, title: "Voice notes", detail: voiceDetail) {
            if model.voice.permission == .microphoneDenied {
                Button("Enable") { model.voice.openMicrophoneSettings() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button("Clear") { model.clearVoiceNotes() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.voice.notes.isEmpty)
        }
    }

    private var voiceColor: Color {
        switch model.voice.permission {
        case .microphoneDenied: return .orange
        case .unknown, .ready, .speechDenied: return model.isVoiceHotkeyRegistered ? .green : .orange
        }
    }

    private var voiceDetail: String {
        if model.voice.permission == .microphoneDenied {
            return "Microphone access needed — enable it, then press ⇧⌘M again."
        }
        guard model.isVoiceHotkeyRegistered else {
            return "⇧⌘M could not be registered — another app may own it. "
                + "The mic button in the notch peek always works."
        }
        let count = model.voice.notes.count
        return "\(count) note\(count == 1 ? "" : "s") · ⇧⌘M records, on-device"
    }

    private func toggleRow(isOn: Binding<Bool>, title: String, detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Clipboard

    /// Everything the notch is holding, at a size you can actually read — the
    /// notch surface is a picker you glance at, this is where you go to see what
    /// is in there and throw things out.
    private var clipboardTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("\(model.clipboard.items.count) of \(ClipboardStore.maxItems)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !model.clipboardCapture {
                    Label("Capture is off", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Clear all") { model.clearClipboardHistory() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.clipboard.items.isEmpty)
            }

            if model.clipboard.items.isEmpty {
                emptyClipboard
            } else {
                card {
                    ForEach(Array(model.clipboard.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 56) }
                        clipRow(item)
                    }
                }
            }
        }
        .onAppear { model.clipboard.refreshFileStates() }
    }

    private var emptyClipboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.clipboardCapture ? "Nothing copied yet." : "Clipboard history is off.")
                .font(.callout.weight(.medium))
            Text(model.clipboardCapture
                 ? "Copy anything and it shows up here, newest first. ⇧⌘V opens the notch."
                 : "Turn it on under Status to start keeping what you copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape.fill(.background.secondary))
        .overlay(cardShape.strokeBorder(.separator.opacity(0.5), lineWidth: 1))
    }

    private func clipRow(_ item: ClipItem) -> some View {
        let isStale = model.clipboard.isStale(item)
        return HStack(spacing: 12) {
            clipThumbnail(item)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(isStale ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.clipboard.preview(for: item))
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .textSelection(.enabled)

                HStack(spacing: 5) {
                    if let icon = model.clipboard.sourceIcon(for: item) {
                        Image(nsImage: icon).resizable().frame(width: 11, height: 11)
                    }
                    Text(clipCaption(item))
                }
                .font(.caption)
                .foregroundStyle(isStale ? AnyShapeStyle(Color.orange.opacity(0.8)) : AnyShapeStyle(.secondary))
            }

            Spacer(minLength: 8)

            // Puts it back on the pasteboard without going through the notch —
            // the same `copy` the card uses, so the auto-generated marker and
            // the change-count bookkeeping come along with it.
            Button("Copy") { model.clipboard.copy(item) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isStale)

            Button {
                model.clipboard.remove(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove this clipping")
            .accessibilityLabel("Remove this clipping")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func clipCaption(_ item: ClipItem) -> String {
        var parts: [String] = []
        parts.append(model.clipboard.isStale(item) ? "File missing" : item.kind.label)
        if let name = item.source?.name { parts.append(name) }
        parts.append(Self.clock.string(from: item.lastCopiedAt))
        if item.copyCount > 1 { parts.append("copied \(item.copyCount)×") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func clipThumbnail(_ item: ClipItem) -> some View {
        if let image = model.clipboard.rowImage(for: item) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: item.kind == .files ? .fit : .fill)
        } else {
            ZStack {
                Rectangle().fill(.background.secondary)
                Image(systemName: item.kind.symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Voice

    /// The permanent home for what ⇧⌘M has produced — the notch surface shows
    /// the same list, but it's a picker you glance at and close; this is where
    /// you go to read a transcript in full or clean the list out.
    private var voiceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("\(model.voice.notes.count) note\(model.voice.notes.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if model.voice.permission == .microphoneDenied {
                    Label("Microphone access needed", systemImage: "mic.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Clear all") { model.clearVoiceNotes() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.voice.notes.isEmpty)
            }

            if model.voice.notes.isEmpty {
                emptyVoice
            } else {
                card {
                    ForEach(Array(model.voice.notes.enumerated()), id: \.element.id) { index, note in
                        if index > 0 { Divider().padding(.leading, 46) }
                        voiceNoteRow(note)
                    }
                }
            }
        }
    }

    private var emptyVoice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No voice notes yet.")
                .font(.callout.weight(.medium))
            Text("⇧⌘M starts recording from anywhere. Speech is transcribed on this Mac; "
                 + "if that isn't possible the recording itself is kept instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardShape.fill(.background.secondary))
        .overlay(cardShape.strokeBorder(.separator.opacity(0.5), lineWidth: 1))
    }

    private func voiceNoteRow(_ note: VoiceNote) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Rectangle().fill(.background.secondary)
                Image(systemName: note.isTranscript ? "text.quote" : "waveform")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(voicePreview(note))
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(voiceCaption(note))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !note.isTranscript {
                Button(model.voice.playingID == note.id ? "Stop" : "Play") {
                    model.voice.togglePlayback(note)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button(model.voice.justCopied == note.id ? "Copied" : "Copy") {
                model.voice.copy(note)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                model.voice.remove(note)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove this note")
            .accessibilityLabel("Remove this note")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func voicePreview(_ note: VoiceNote) -> String {
        if case .transcript(let text) = note.content { return text }
        return "Voice recording"
    }

    private func voiceCaption(_ note: VoiceNote) -> String {
        let minutes = Int(note.duration) / 60
        let seconds = Int(note.duration) % 60
        let duration = String(format: "%d:%02d", minutes, seconds)
        return "\(note.isTranscript ? "Transcript" : "Recording") · \(duration) · \(Self.clock.string(from: note.createdAt))"
    }

    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("Paste this into ~/.claude/settings.json instead:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.manualSnippet)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Button("Copy snippet") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.manualSnippet, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.orange.opacity(0.08))
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        )
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Events")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                Spacer()
                if !model.log.isEmpty {
                    Text("\(model.log.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            // No inner `ScrollView` any more: this pane already lives inside the
            // window's scroller, and a nested one gives you two scrollbars, a
            // fixed-height window inside a resizable one, and a wheel that
            // scrolls whichever container the pointer happens to be over.
            Group {
                if model.log.isEmpty {
                    Text("Nothing yet — prompts show up here as they arrive.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(model.log.reversed()) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Self.clock.string(from: entry.at))
                                    .foregroundStyle(.tertiary)
                                Text(entry.text)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption.monospaced())
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(cardShape.fill(.background.secondary))
            .overlay(cardShape.strokeBorder(.separator.opacity(0.5), lineWidth: 1))
        }
    }

    // MARK: - Building blocks

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(cardShape.fill(.background.secondary))
            .overlay(cardShape.strokeBorder(.separator.opacity(0.5), lineWidth: 1))
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 34)
    }

    private func row<Controls: View>(
        color: Color,
        title: String,
        detail: String,
        logo: String? = nil,
        mono: Bool = false,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        HStack(spacing: 10) {
            statusDot(color)
            if let logo {
                BrandMark(logo, size: 16)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(mono ? .caption.monospaced() : .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) { controls() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func statusDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.25), lineWidth: 4))
            .frame(width: 14, alignment: .center)
    }

    private var serverColor: Color {
        switch model.serverState {
        case .listening: return .green
        case .starting: return .yellow
        case .failed: return .red
        }
    }

    private var serverDescription: String {
        switch model.serverState {
        case .starting: return "starting…"
        case .listening(let port): return "127.0.0.1:\(port)\(ClaudeSettings.permissionPath)"
        case .failed(let message): return message
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
