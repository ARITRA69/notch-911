//
//  VoiceNoteView.swift
//  notch-911
//
//  The voice surface: a recording HUD while the mic is live, a list of what it
//  produced once it isn't.
//
//  Two states, never both — `store.phase` already forbids it — so this is one
//  `Group` switching wholesale rather than an overlay, the same shape
//  `NotchPromptView.content` uses one level up for prompt vs. clipboard vs. peek.
//

import SwiftUI

/// Voice notes as they sit in the notch: the recording HUD or the list, a way
/// back to the peek, and `esc` to leave — the same frame the clipboard and
/// Snake surfaces wear.
struct VoiceSurface: View {
    let coordinator: PromptCoordinator
    let store: VoiceNoteStore

    /// The keyboard's cursor. Starts on the newest note so ↵ copies the thing
    /// you just said without an arrow press first — the note you want is almost
    /// always the one that just landed.
    @State private var selection: VoiceNote.ID?
    @State private var scrollTarget: VoiceNote.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            if store.isCapturing || store.phase == .transcribing {
                RecordingHUD(store: store)
            } else if store.permission == .microphoneDenied {
                permissionBlocked
            } else if store.notes.isEmpty {
                empty
            } else {
                NoteList(store: store, selection: $selection, scrollTarget: $scrollTarget)
            }
            footer
        }
        // Fills the width the panel hands down rather than naming one. The
        // panel's `voiceWidth` is the *outer* box; it then spends 28pt a side on
        // padding, so a hard 420 here renders 32pt wider than the space it was
        // given and hangs off the right edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shortcuts)
        .onAppear { selectNewestIfNeeded() }
        // Every way out of this surface lands here — `esc`, the back chevron,
        // a click elsewhere collapsing the panel. Audio still playing out of a
        // notch that isn't on screen has no visible control to stop it.
        .onDisappear { store.stopPlayback() }
        // A note saved while the surface is open should take the cursor: it is
        // the one the user just made, and ↵ is what they reach for next.
        .onChange(of: store.notes.first?.id) { _, newest in
            guard let newest, store.justSaved == newest else { return }
            selection = newest
            scrollTarget = newest
        }
    }

    private func selectNewestIfNeeded() {
        guard selection == nil || !store.notes.contains(where: { $0.id == selection }) else { return }
        selection = store.notes.first?.id
    }

    private var heading: some View {
        HStack(spacing: 4) {
            // No way back to the peek mid-note: the note is the only thing
            // happening, and the way out of this surface is one of its own three
            // answers — or clicking the notch again to go back to the indicator.
            if !store.isBusy {
                Button { coordinator.back() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the notch overview")
            }
            Image(systemName: "waveform")
            Text(store.isBusy ? "Voice note" : "Voice notes")
            Spacer(minLength: 0)
            if !store.notes.isEmpty, !store.isBusy {
                Text("\(store.notes.count)").monospacedDigit()
            }
            if !store.isCapturing, store.phase != .transcribing {
                Button { store.start() } label: {
                    Image(systemName: "mic.fill")
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start a voice note")
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.35))
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.25))
            Text("⇧⌘M to record a note")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var permissionBlocked: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Microphone access needed", systemImage: "mic.slash")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
            Text("notch-911 can't record a note without it. Enable it in Privacy & Security, then try again.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { store.openMicrophoneSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var footer: some View {
        Text(footerText)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.25))
    }

    private var footerText: String {
        if store.isPaused { return "Paused · ⇧⌘M or ⎋ to save · space to cancel" }
        if store.isRecording { return "⇧⌘M or ⎋ to save · space to cancel" }
        if store.phase == .transcribing { return "Transcribing on this Mac…" }
        if store.notes.isEmpty { return "⇧⌘M to record · ⎋ close" }
        return "↵ copy · ⌫ remove · ⇧⌘M record · ⎋ close"
    }

    /// `esc` while idle closes the surface; `esc` mid-recording stops and keeps
    /// what was captured, matching `VoiceNoteStore.cancel()`'s own doc — a
    /// fallback nobody asked to discard is not a fallback. Space is the one
    /// explicit way to throw a recording away.
    ///
    /// The list keys are the clipboard's, because this is the clipboard's shape
    /// of surface — but they're all inert while the mic is live, where the only
    /// two answers that mean anything are "keep it" and "throw it away".
    private var shortcuts: some View {
        ZStack {
            Button("") {
                if store.isCapturing { store.stop() } else { coordinator.closeVoice() }
            }
            .keyboardShortcut(.escape, modifiers: [])
            Button("") { store.cancel() }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { move(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("") { copySelected() }
                .keyboardShortcut(.return, modifiers: [])
            Button("") { deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var selectedNote: VoiceNote? {
        store.notes.first { $0.id == selection }
    }

    /// Clamped rather than wrapped, for the reason `ClipboardCard.move` gives:
    /// wrapping teleports the viewport and loses the reader.
    private func move(_ delta: Int) {
        guard !store.isCapturing, !store.notes.isEmpty else { return }
        let current = store.notes.firstIndex { $0.id == selection } ?? -1
        let next = min(max(current + delta, 0), store.notes.count - 1)
        selection = store.notes[next].id
        scrollTarget = selection
    }

    private func copySelected() {
        guard !store.isCapturing, let note = selectedNote else { return }
        store.copy(note)
    }

    private func deleteSelected() {
        guard !store.isCapturing, let note = selectedNote else { return }
        let index = store.notes.firstIndex { $0.id == note.id }
        withAnimation(.easeOut(duration: 0.16)) { store.remove(note) }
        // Leave the cursor where the eye already is, rather than dropping it
        // back at the top of the list.
        if let index {
            selection = store.notes.indices.contains(index)
                ? store.notes[index].id
                : store.notes.last?.id
        }
    }
}

// MARK: - Recording HUD

private struct RecordingHUD: View {
    let store: VoiceNoteStore

    /// The same pair the collapsed indicator shows — mic then meter — restated
    /// above the options so that clicking through reads as the indicator
    /// growing three buttons, rather than as a different screen arriving.
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: store.isPaused ? "pause.fill" : "mic.fill")
                    .font(.system(size: 10, weight: .bold))
                    // A steady glyph while paused: something that keeps pulsing
                    // is the one thing a paused recorder must not look like.
                    .foregroundStyle(store.isPaused ? .white.opacity(0.55) : .red)
                    .opacity(pulse && !store.isPaused ? 1 : 0.45)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                LevelMeter(level: level, bars: 9, spacing: 2)
                    .frame(width: 58, height: 12)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 4)
                Text(elapsedLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }

            // Centred rather than pushed to the corners: three buttons split
            // left-and-right read as two unrelated groups, and the middle one
            // has nowhere to sit.
            HStack(spacing: 8) {
                Button("Discard", role: .destructive) { store.cancel() }
                    .tint(.red)
                Button(store.isPaused ? "Resume" : "Pause") {
                    store.isPaused ? store.resume() : store.pause()
                }
                .tint(.gray)
                Button("Save") { store.stop() }
                    .tint(.blue)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            // Nothing here means anything once the audio is in the recognizer's
            // hands — there is no note left to discard, pause or save.
            .disabled(store.phase == .transcribing)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { pulse = true }
    }

    @State private var pulse = false

    private var statusLabel: String {
        if store.phase == .transcribing { return "Transcribing…" }
        return store.isPaused ? "Paused" : "Listening…"
    }

    /// Keeps showing the frozen count while paused — a timer that blanks out
    /// reads as "the recording is gone".
    private var elapsedLabel: String {
        let elapsed: TimeInterval
        switch store.phase {
        case .recording(let value, _): elapsed = value
        case .paused(let value): elapsed = value
        default: return ""
        }
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var level: Double {
        guard case .recording(_, let level) = store.phase else { return 0 }
        return level
    }
}

/// Bars rather than a continuous waveform: there is no history to draw a
/// waveform *from* — only the current buffer's loudness exists at any instant —
/// so this is a level meter wearing a waveform's clothes, and bars are the
/// honest version of that.
///
/// Not private: the collapsed notch indicator draws the same meter at seven
/// bars, and two implementations of one thing would drift.
struct LevelMeter: View {
    let level: Double
    var bars: Int = 16
    var spacing: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: spacing) {
                ForEach(0..<bars, id: \.self) { index in
                    // Bars nearer the centre light up first, so a quiet voice
                    // still shows *something* moving instead of one lonely bar
                    // at the left edge.
                    let distanceFromCenter = abs(Double(index) - Double(bars - 1) / 2)
                    let threshold = distanceFromCenter / (Double(bars) / 2)
                    let active = level > threshold * 0.9
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(active ? 0.85 : 0.15))
                }
            }
            .animation(.easeOut(duration: 0.08), value: level)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

// MARK: - List

private struct NoteList: View {
    let store: VoiceNoteStore
    @Binding var selection: VoiceNote.ID?
    @Binding var scrollTarget: VoiceNote.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Clear all") { store.removeAll() }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.notes) { note in
                            NoteRow(note: note, store: store, isSelected: selection == note.id)
                                .id(note.id)
                                .onTapGesture { selection = note.id }
                        }
                    }
                }
                .frame(maxHeight: 280)
                // Only the keyboard scrolls the list — following the pointer
                // would fight the user's own scrolling.
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(target, anchor: .center) }
                    scrollTarget = nil
                }
            }
        }
    }
}

private struct NoteRow: View {
    let note: VoiceNote
    let store: VoiceNoteStore
    let isSelected: Bool

    @State private var hovered = false

    private var isPlaying: Bool { store.playingID == note.id }

    private var preview: String {
        if case .transcript(let text) = note.content { return text }
        return "Voice recording"
    }

    private var durationLabel: String {
        let minutes = Int(note.duration) / 60
        let seconds = Int(note.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: note.createdAt, relativeTo: Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: note.isTranscript ? "text.quote" : "waveform")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                Text("\(relativeTime) · \(durationLabel)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
            }

            Spacer(minLength: 0)

            // Shown on hover *or* selection: the keyboard user never hovers,
            // and a row you can act on with ↵ should look like one.
            if hovered || isSelected {
                HStack(spacing: 8) {
                    // A recording gets both — play it, or copy the file out.
                    // Copy is on every row because a list of notes whose copy
                    // button depends on how the transcription went is a list
                    // you can't build a habit around.
                    if !note.isTranscript {
                        Button { store.togglePlayback(note) } label: {
                            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPlaying ? "Stop" : "Play")
                    }

                    Button { store.copy(note) } label: {
                        Image(systemName: store.justCopied == note.id ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(note.isTranscript ? "Copy text" : "Copy recording")

                    Button { store.remove(note) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete")
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeOut(duration: 0.5), value: store.justSaved)
        .onHover { hovered = $0 }
    }

    private var rowBackground: Color {
        if store.justSaved == note.id { return .white.opacity(0.12) }
        if isSelected { return .white.opacity(0.1) }
        return hovered ? .white.opacity(0.06) : .clear
    }
}
