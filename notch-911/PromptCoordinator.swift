//
//  PromptCoordinator.swift
//  notch-911
//
//  Bridges the blocked hook request to the UI. The server awaits `response(to:)`;
//  the panel resolves it. Everything here is main-actor state, so the server's
//  Task hops once on the way in and once on the way out.
//

import Foundation
import Observation

/// What the notch is showing when no prompt is blocked. One slot rather than a
/// Bool per surface: the peek and the clipboard are mutually exclusive by
/// construction, and two Bools would spell four states — one of which is
/// nonsense every guard in `evaluateHover` would then have to defend against.
nonisolated enum IdleSurface: Sendable, Equatable, CaseIterable {
    /// Hover-dwell over the notch. Opens on its own, so it may never take the
    /// keyboard.
    case peek
    /// Clipboard history. Only ever opened by an explicit act — ⇧⌘V or the chip
    /// in the peek — which is what earns it the keyboard.
    case clipboard
    /// The Snake board. Deliberately has no hotkey: the clipboard is something
    /// you summon over whatever you were doing, a game is somewhere you go.
    case game
    /// The voice recorder and its saved notes. Unlike the game, this *does*
    /// have a hotkey — ⇧⌘M both opens the surface and starts the recording in
    /// one press, the same way ⇧⌘V both opens and shows.
    case voice
    /// The camera, as a mirror. Like the game and unlike the clipboard it has
    /// no hotkey — it is somewhere you go, not something you summon over what
    /// you were doing.
    case mirror
    /// Instagram, in a web view. Further down the "somewhere you go" axis than
    /// the game, and the only surface here that reaches a third-party account —
    /// so it is opt-in, and has no hotkey either.
    case reels
    case none
}

extension IdleSurface {
    /// Whether a prompt taking this surface away should hand it back once the
    /// queue drains. Only the reels: the peek was never asked for (see
    /// `advance()`), the clipboard is a picker you finish in seconds and can
    /// re-summon with a keystroke, and the game pauses exactly where it stood.
    /// The reels are the one surface the user is *inside* — a scroll position
    /// and a playing video — that this app, rather than the user, interrupts.
    var survivesPreemption: Bool { self == .reels }
}

nonisolated enum ExternalSubmissionState: Sendable, Equatable {
    case idle
    case requestingPermission
    case submitting
    case confirmed
    case failed(String)
}

@MainActor
@Observable
final class PromptCoordinator {

    /// Snapshot of which agents are wired up, pushed in by `AppModel` so the
    /// peek surface can report status without the coordinator reaching back
    /// into the app model and forming a cycle.
    struct AgentStatus: Sendable, Equatable {
        var claudeConnected = false
        var codexConnected = false
        var port: UInt16?
    }

    /// The prompt currently on screen. §4 — never show two at once.
    private(set) var current: Prompt?
    /// How many more are stacked up behind it, for the "2 more" indicator.
    private(set) var waitingCount: Int = 0
    /// The idle surface currently on the notch. Mutated only through
    /// `setIdleSurface` — the pointer latch and the visibility callback have to
    /// move with it.
    private(set) var idleSurface: IdleSurface = .none

    /// Kept as a computed property so the hover-peek call sites read the way
    /// they always did.
    var isPeeking: Bool { idleSurface == .peek }

    /// Anything that should stop the panel being click-through. The collapsed
    /// mini player deliberately isn't one — it's decoration, and a 720×620
    /// window that eats clicks for a 22pt disc is a bug.
    var isInteractive: Bool { current != nil || idleSurface != .none }

    /// True only while the reels are genuinely the thing on the notch. Media
    /// suspension keys off this and nothing else — a detached `WKWebView` is
    /// only detached, and keeps playing audio into a room where the surface it
    /// came from is no longer on screen.
    var isReelsLive: Bool { current == nil && idleSurface == .reels }

    /// The same question for the board. Both exist because a surface being
    /// *mounted* and a surface being *live* are different things here: the panel
    /// keeps content on screen for 800ms after a collapse so it can shrink back
    /// into the notch rather than vanish, and anything with a clock in it has to
    /// stop at the start of that window rather than the end of it.
    var isGameLive: Bool { current == nil && idleSurface == .game }

    /// Surfaces allowed to take the keyboard. A peek never may: it opens on
    /// hover alone, and swallowing the next keystroke meant for the user's
    /// editor is the one unforgivable thing a hover surface can do.
    var wantsKeyboard: Bool {
        current != nil
            || idleSurface == .clipboard
            || idleSurface == .game
            || idleSurface == .voice
            || idleSurface == .mirror
            || idleSurface == .reels
    }

    /// Fires as the peek opens and closes, so pollers can run only while the
    /// surface is on screen.
    @ObservationIgnored var onPeekChange: ((Bool) -> Void)?
    /// Everything still blocked — queued behind the current prompt, or stranded
    /// by an `esc` dismissal.
    private(set) var stranded: [Prompt] = []

    var agentStatus = AgentStatus()

    /// Whether the reels surface is switched on, pushed in by `AppModel` the
    /// same way `agentStatus` is. The peek has to decide whether to draw the
    /// chip, and the coordinator has no business reading `UserDefaults` itself.
    var reelsEnabled = false

    /// Dwell before the peek opens.
    static let peekDelayMilliseconds = 300
    /// Grace after the pointer leaves, so clipping the edge mid-gesture doesn't
    /// make the panel flicker.
    static let peekCloseGraceMilliseconds = 250

    @ObservationIgnored private var dwell: Task<Void, Never>?
    @ObservationIgnored private var pointerOnSensor = false
    @ObservationIgnored private var pointerOnPanel = false
    /// Set when the peek is reached by an explicit act — the clipboard's back
    /// button — rather than by hover. A hover-opened peek closes when the
    /// pointer leaves, but a navigated-to peek may never have had the pointer
    /// inside at all: the clipboard is 100pt wider, so the very button that
    /// summoned the peek sits outside the peek's footprint, and the width
    /// change evicts the pointer mid-swap. Closing on that "exit" slams the
    /// surface shut half a second after the user asked for it. The hold lasts
    /// until the pointer genuinely touches the peek or the sensor once; from
    /// then on the normal hover-to-close rules apply.
    @ObservationIgnored private var peekAwaitsPointer = false

    /// The surface a prompt displaced, held so `advance()` can hand it back.
    /// Written in exactly one place — `setIdleSurface` — and cleared by any
    /// surface change the *user* drives, so a restore is only ever the undo of
    /// an interruption this app caused.
    @ObservationIgnored private var preemptedSurface: IdleSurface = .none

    @ObservationIgnored private var waiting: [Prompt] = [] {
        didSet { stranded = waiting }
    }

    @ObservationIgnored
    private var continuations: [UUID: CheckedContinuation<PromptResponse?, Never>] = [:]
    @ObservationIgnored private var externalPromptIDs: Set<UUID> = []
    private(set) var externalSubmissionStates: [String: ExternalSubmissionState] = [:]

    /// Called when the panel should become visible or go away.
    @ObservationIgnored var onVisibilityChange: ((Bool) -> Void)?
    @ObservationIgnored var onSubmitExternal: ((Prompt, [CodexQuestionAnswer]) -> Void)?
    @ObservationIgnored var onExternalResolution: ((String) -> Void)?

    // MARK: Server side

    /// Suspends until the user answers. `nil` means "no decision" — the caller
    /// should return an empty 200 and let the agent's own flow take over. Never
    /// throws and never times out on our side: the hook's own timeout is the
    /// ceiling, and if the app dies the socket closes and the agent falls back
    /// to its normal prompt anyway.
    ///
    /// Task cancellation means the *client* gave up — the call was resolved in
    /// the session or the turn was interrupted — so the card is retracted:
    /// leaving it up invites answering a question that no longer exists.
    func response(to prompt: Prompt) async -> PromptResponse? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // A cancellation that lands before this runs would otherwise
                // strand the continuation forever.
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                continuations[prompt.id] = continuation
                if current == nil {
                    present(prompt)
                } else {
                    waiting.append(prompt)
                    waitingCount = waiting.count
                }
            }
        } onCancel: {
            // Fires on the canceller's context; all queue state is main-actor.
            // Ordering is safe either way: on this actor the continuation is
            // registered before the suspension ever yields to this task, and
            // an earlier cancellation is caught by the guard above.
            Task { @MainActor in self.retract(prompt.id) }
        }
    }

    /// Removes a prompt whose hook connection died before a decision. A no-op
    /// when the prompt was already resolved, so racing a real answer is safe.
    private func retract(_ promptID: UUID) {
        if let continuation = continuations.removeValue(forKey: promptID) {
            continuation.resume(returning: nil)
        }
        if current?.id == promptID {
            advance()
        } else if let index = waiting.firstIndex(where: { $0.id == promptID }) {
            waiting.remove(at: index)
            waitingCount = waiting.count
        }
    }

    /// Presents a prompt observed outside the blocking hook channel. Submission
    /// is delegated to the Accessibility bridge while this coordinator retains
    /// the UI state and waits for rollout confirmation.
    func observe(_ prompt: Prompt) {
        guard let externalID = prompt.externalID else { return }
        let alreadyShown = current?.externalID == externalID
            || waiting.contains(where: { $0.externalID == externalID })
        guard !alreadyShown else { return }

        externalPromptIDs.insert(prompt.id)
        externalSubmissionStates[externalID] = .idle
        if current == nil {
            present(prompt)
        } else {
            waiting.append(prompt)
            waitingCount = waiting.count
        }
    }

    /// Removes an observed card as soon as Codex records the tool output. This
    /// also handles the user answering directly in Codex while the notch is up.
    func externalPromptResolved(_ externalID: String) {
        onExternalResolution?(externalID)
        externalSubmissionStates[externalID] = .confirmed
        if current?.externalID == externalID {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.finishExternalPrompt(externalID)
            }
            return
        }
        finishExternalPrompt(externalID)
    }

    private func finishExternalPrompt(_ externalID: String) {
        if let prompt = current, prompt.externalID == externalID {
            externalPromptIDs.remove(prompt.id)
            externalSubmissionStates.removeValue(forKey: externalID)
            advance()
            return
        }
        waiting.removeAll { prompt in
            guard prompt.externalID == externalID else { return false }
            externalPromptIDs.remove(prompt.id)
            return true
        }
        externalSubmissionStates.removeValue(forKey: externalID)
        waitingCount = waiting.count
    }

    // MARK: UI side

    func resolve(_ prompt: Prompt, with response: PromptResponse) {
        guard let continuation = continuations.removeValue(forKey: prompt.id) else {
            guard externalPromptIDs.remove(prompt.id) != nil else { return }
            if let externalID = prompt.externalID {
                externalSubmissionStates.removeValue(forKey: externalID)
                onExternalResolution?(externalID)
            }
            advance()
            return
        }
        continuation.resume(returning: response)
        advance()
    }

    func submitExternal(_ prompt: Prompt, answers: [CodexQuestionAnswer]) {
        guard let externalID = prompt.externalID,
              externalPromptIDs.contains(prompt.id),
              externalSubmissionStates[externalID] != .submitting
        else { return }
        onSubmitExternal?(prompt, answers)
    }

    func setExternalSubmissionState(_ state: ExternalSubmissionState, for externalID: String) {
        guard activeExternalIDs.contains(externalID) else { return }
        externalSubmissionStates[externalID] = state
    }

    func externalSubmissionState(for prompt: Prompt) -> ExternalSubmissionState {
        guard let externalID = prompt.externalID else { return .idle }
        return externalSubmissionStates[externalID] ?? .idle
    }

    func isExternalPromptActive(_ externalID: String) -> Bool {
        activeExternalIDs.contains(externalID)
    }

    private var activeExternalIDs: Set<String> {
        Set(([current].compactMap { $0?.externalID }) + waiting.compactMap(\.externalID))
    }

    /// `esc` — collapse without answering. The session stays blocked and the
    /// prompt goes to the back of the queue, per §4.
    func dismissCurrent() {
        guard let prompt = current else { return }
        waiting.append(prompt)
        waitingCount = waiting.count
        current = nil
        // Cleared explicitly: this is the one exit that never calls
        // `setIdleSurface`, so the single-writer rule can't do it for us. And
        // `esc` means "get out of my way" — honouring that literally beats
        // second-guessing it by reopening the feed the prompt interrupted.
        preemptedSurface = .none
        onVisibilityChange?(false)
    }

    /// Re-show whatever is waiting. Used by the peek surface, the status window
    /// and, later, the global hotkey.
    func resurface() {
        guard current == nil, !waiting.isEmpty else { return }
        dwell?.cancel()
        setIdleSurface(.none)
        advance()
    }

    /// Bring a specific stranded prompt back, rather than whatever is at the
    /// head of the queue.
    func resurface(_ prompt: Prompt) {
        guard current == nil, let index = waiting.firstIndex(where: { $0.id == prompt.id }) else { return }
        dwell?.cancel()
        setIdleSurface(.none)
        let chosen = waiting.remove(at: index)
        waitingCount = waiting.count
        present(chosen)
    }

    // MARK: Idle surface

    /// Every idle-surface change goes through here. Three things have to happen
    /// together, and getting any one wrong is a ghost-peek bug:
    ///
    /// 1. `onPeekChange` fires only on transitions in and out of `.peek`. The
    ///    media poller is its only listener, and the clipboard card shows no
    ///    progress bar — speeding the poll up for it would spawn `osascript`
    ///    once a second for nothing.
    /// 2. `pointerOnPanel` is cleared whenever the peek isn't up. The flag only
    ///    means anything while the peek owns the surface, and SwiftUI never
    ///    delivers the matching `onHover(false)` once the panel is ordered out
    ///    or the card is unmounted — so a stale `true` latches, and the next
    ///    stray sensor event re-opens a peek from a pointer that left the screen
    ///    minutes ago.
    /// 3. `onVisibilityChange` fires on *every* change, not just visible↔hidden.
    ///    `setVisible` is where `ignoresMouseEvents` and key status are decided,
    ///    so a peek→clipboard swap that skipped it would leave the panel unable
    ///    to take a keystroke. `refreshPanelVisibility` recomputes from scratch
    ///    and ignores the Bool, so re-entering it is free.
    /// 4. `preemptedSurface` is maintained here rather than in `present()`, so
    ///    there is exactly one writer. A prompt being up means the notch was
    ///    taken; anything else means the user is driving, and any surface they
    ///    choose — or any close they ask for — retires the memo. A restore they
    ///    didn't earn reads as the notch reopening by itself.
    private func setIdleSurface(_ surface: IdleSurface) {
        let previous = idleSurface
        let wasPeeking = previous == .peek
        idleSurface = surface
        if current != nil {
            // Only the *first* prompt in a queue leaves a memo. The second
            // arrives to an already-empty surface and must not overwrite what
            // the first displaced.
            if previous.survivesPreemption { preemptedSurface = previous }
        } else {
            preemptedSurface = .none
        }
        if surface != .peek {
            pointerOnPanel = false
            // The pointer hold is a property of one navigated-to peek; any
            // other surface change retires it so a later hover-opened peek
            // can't inherit an exemption from its own close rule.
            peekAwaitsPointer = false
            if wasPeeking { onPeekChange?(false) }
        } else if !wasPeeking {
            onPeekChange?(true)
        }
        onVisibilityChange?(current != nil || surface != .none)
    }

    /// ⇧⌘V, and the chip in the peek. Toggling closed rather than re-opening is
    /// what makes the hotkey feel like a drawer instead of a command.
    func toggleClipboard() {
        // A blocked prompt outranks it (§4 — never two surfaces at once). It is
        // also the one the user can't summon back with a keystroke.
        guard current == nil else { return }
        dwell?.cancel()
        setIdleSurface(idleSurface == .clipboard ? .none : .clipboard)
    }

    /// From the peek chip, where "toggle" would be ambiguous.
    func openClipboard() {
        guard current == nil, idleSurface != .clipboard else { return }
        dwell?.cancel()
        setIdleSurface(.clipboard)
    }

    /// The chip in the peek. No hotkey, deliberately — see the enum.
    func openGame() {
        guard current == nil, idleSurface != .game else { return }
        dwell?.cancel()
        setIdleSurface(.game)
    }

    /// `esc`, and the panel losing key. Collapses outright for the same reason
    /// the clipboard does.
    func closeGame() {
        guard idleSurface == .game else { return }
        dwell?.cancel()
        setIdleSurface(.none)
    }

    /// The hotkey handler calls this every time it fires while nothing is
    /// recording yet — including when the voice surface is already open and
    /// showing the note list, which is exactly when "start a new note" should
    /// still work.
    func openVoice() {
        guard current == nil, idleSurface != .voice else { return }
        dwell?.cancel()
        setIdleSurface(.voice)
    }

    /// Mirrors `VoiceNoteStore.isCapturing`, pushed down by the app model on the
    /// same edge that brings the panel on screen. The coordinator can't read the
    /// store directly — nothing else in it reaches sideways into a store — and
    /// two things here need the answer: the hover peek must not open over a
    /// recording indicator, and a click on the notch has to mean something while
    /// one is showing.
    @ObservationIgnored var voiceIsCapturing = false

    /// A click on the notch itself, delivered by the hover sensor. Only means
    /// anything mid-note: the collapsed indicator *is* the control, and this is
    /// the way to Discard / Pause / Save. Toggles, so clicking it again puts the
    /// note back to just the indicator rather than stranding the panel open.
    func tappedSensor() {
        guard voiceIsCapturing, current == nil else { return }
        dwell?.cancel()
        setIdleSurface(idleSurface == .voice ? .none : .voice)
    }

    /// `esc` while idle, and the panel losing key. A live recording is stopped
    /// by `VoiceSurface`'s own `esc` handler *before* this ever runs — see its
    /// `shortcuts` — so by the time the surface actually closes there is
    /// nothing left capturing to interrupt.
    func closeVoice() {
        guard idleSurface == .voice else { return }
        dwell?.cancel()
        setIdleSurface(.none)
    }

    /// The chip in the peek. No hotkey to toggle against, so this only opens.
    func openMirror() {
        guard current == nil, idleSurface != .mirror else { return }
        dwell?.cancel()
        setIdleSurface(.mirror)
    }

    /// `esc`, and the panel losing key. Collapses outright rather than falling
    /// back to the peek, for the reason the clipboard gives — and with one of
    /// its own: the camera light stays lit for as long as the surface is
    /// mounted, so "close" has to mean closed.
    func closeMirror() {
        guard idleSurface == .mirror else { return }
        dwell?.cancel()
        setIdleSurface(.none)
    }

    /// The chip in the peek, which only exists once the feature is switched on.
    /// Gated on `reelsEnabled` as well as drawn from it, so a chip left over
    /// from a stale render can't open a surface the user has since disabled.
    func openReels() {
        guard current == nil, reelsEnabled, idleSurface != .reels else { return }
        dwell?.cancel()
        setIdleSurface(.reels)
    }

    /// `esc`, another app taking key, and the settings switch going off. The
    /// session object outlives the surface, so this is a pause: reopening lands
    /// on the same scroll position with the same login.
    func closeReels() {
        guard idleSurface == .reels else { return }
        dwell?.cancel()
        setIdleSurface(.none)
    }

    /// The ← in the clipboard heading — hand the surface back to the peek
    /// rather than collapsing. The pointer latch is deliberately left alone:
    /// no enter event was delivered while the clipboard owned the surface, so
    /// a latch set here would have no guaranteed exit to clear it. Instead the
    /// peek is marked as awaiting the pointer, which suspends hover-to-close
    /// until the user actually reaches it — see `peekAwaitsPointer`.
    func backToPeek() {
        guard idleSurface == .clipboard
                || idleSurface == .game
                || idleSurface == .voice
                || idleSurface == .mirror
                || idleSurface == .reels else {
            return
        }
        dwell?.cancel()
        peekAwaitsPointer = true
        setIdleSurface(.peek)
    }

    /// `esc`, a click outside, and copying an item.
    func closeClipboard() {
        guard idleSurface == .clipboard else { return }
        dwell?.cancel()
        // Collapses outright rather than falling back to the peek, even with the
        // pointer still over the notch — the same reasoning as `advance()`:
        // re-opening into a surface the user didn't ask for reads as a glitch.
        setIdleSurface(.none)
    }

    // MARK: Hover peek

    /// The pointer entered or left the notch sensor.
    func hoverChanged(_ hovering: Bool) {
        pointerOnSensor = hovering
        if hovering { peekAwaitsPointer = false }
        evaluateHover()
    }

    /// A drag is hovering the notch. Opens with no dwell — the user is already
    /// holding a file, and making them wait out a delay mid-drag reads as the
    /// target not working.
    func dragOverSensor(_ targeted: Bool) {
        pointerOnSensor = targeted
        guard targeted else {
            evaluateHover()
            return
        }
        dwell?.cancel()
        // A hotkey-opened clipboard outranks a drag: the user is holding a file,
        // but they asked for the clipboard out loud.
        guard current == nil, idleSurface == .none else { return }
        setIdleSurface(.peek)
    }

    /// The pointer entered or left the expanded panel.
    func peekHoverChanged(_ hovering: Bool) {
        pointerOnPanel = hovering
        if hovering { peekAwaitsPointer = false }
        evaluateHover()
    }

    /// Sensor and panel are two separate windows, so crossing from one to the
    /// other fires an exit and an enter with no guaranteed order. Deciding from
    /// the union of both flags rather than from whichever event arrived last
    /// makes the handoff order-independent — otherwise a late sensor-exit
    /// collapses the panel the instant you reach for a control on it.
    private func evaluateHover() {
        dwell?.cancel()
        let inside = pointerOnSensor || pointerOnPanel

        if inside {
            // A real blocked prompt outranks the idle surface, and so does a
            // clipboard the user deliberately opened. So does a note being
            // recorded: the notch is showing its indicator, and replacing that
            // with the peek — on hover, without being asked — would hide the
            // one control the user has over the recording.
            guard current == nil, idleSurface == .none, !voiceIsCapturing else { return }
            // Short enough to feel immediate, long enough that crossing the
            // notch on the way somewhere else doesn't trigger it. The sensor is
            // only the notch itself, and nothing else lives there, so this can
            // be far tighter than a menu-bar hot corner would allow.
            dwell = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.peekDelayMilliseconds))
                guard !Task.isCancelled, let self,
                      current == nil, idleSurface == .none else { return }
                setIdleSurface(.peek)
            }
        } else {
            // Only the peek closes on pointer exit. The clipboard was opened by
            // an explicit act and is dismissed by one — moving the mouse away to
            // read something is not a decision to close it. A peek still
            // awaiting the pointer is in the same category: the user navigated
            // to it, and the pointer "leaving" a surface it never entered is
            // the width-change eviction, not a decision.
            guard idleSurface == .peek, !peekAwaitsPointer else { return }
            dwell = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.peekCloseGraceMilliseconds))
                guard !Task.isCancelled, let self, idleSurface == .peek else { return }
                setIdleSurface(.none)
            }
        }
    }

    /// Close whatever idle surface is up, whichever it is.
    func closeIdleSurface() {
        dwell?.cancel()
        guard idleSurface != .none else { return }
        setIdleSurface(.none)
    }

    // MARK: Teardown

    /// Fail open (§11). Every blocked session is released with *no* response, so
    /// quitting the app drops the user back into the agent's own prompt rather
    /// than silently denying their work.
    func releaseAll() {
        for (_, continuation) in continuations {
            continuation.resume(returning: nil)
        }
        continuations.removeAll()
        externalPromptIDs.removeAll()
        externalSubmissionStates.removeAll()
        waiting.removeAll()
        waitingCount = 0
        current = nil
        preemptedSurface = .none
        dwell?.cancel()
        setIdleSurface(.none)
    }

    // MARK: Private

    private func present(_ prompt: Prompt) {
        // A prompt always wins over the idle surface. `current` is assigned
        // *before* the setter so the visibility callback sees the new prompt.
        dwell?.cancel()
        current = prompt
        setIdleSurface(.none)
    }

    private func advance() {
        if waiting.isEmpty {
            current = nil
            waitingCount = 0
            // Answering always collapses, even if the pointer is still over the
            // notch — re-opening into a peek the user didn't ask for reads as a
            // glitch rather than a feature. Another dwell brings it back.
            //
            // The exception is a surface a prompt took away. The user asked for
            // that one and this app, not they, closed it; handing it back is
            // finishing the interruption rather than starting something.
            // `current` is cleared first so `setIdleSurface` sees the user, not
            // a prompt, and retires the memo on its own.
            let restored: IdleSurface = reelsEnabled ? preemptedSurface : .none
            dwell?.cancel()
            setIdleSurface(restored)
        } else {
            let next = waiting.removeFirst()
            waitingCount = waiting.count
            present(next)
        }
    }
}
