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
    /// Hover-peek: the idle surface, shown after a dwell over the notch.
    private(set) var isPeeking = false {
        didSet {
            guard isPeeking != oldValue else { return }
            onPeekChange?(isPeeking)
        }
    }

    /// Fires as the peek opens and closes, so pollers can run only while the
    /// surface is on screen.
    @ObservationIgnored var onPeekChange: ((Bool) -> Void)?
    /// Everything still blocked — queued behind the current prompt, or stranded
    /// by an `esc` dismissal.
    private(set) var stranded: [Prompt] = []

    var agentStatus = AgentStatus()

    /// Dwell before the peek opens.
    static let peekDelayMilliseconds = 300
    /// Grace after the pointer leaves, so clipping the edge mid-gesture doesn't
    /// make the panel flicker.
    static let peekCloseGraceMilliseconds = 250

    @ObservationIgnored private var dwell: Task<Void, Never>?
    @ObservationIgnored private var pointerOnSensor = false
    @ObservationIgnored private var pointerOnPanel = false

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
        onVisibilityChange?(false)
    }

    /// Re-show whatever is waiting. Used by the peek surface, the status window
    /// and, later, the global hotkey.
    func resurface() {
        guard current == nil, !waiting.isEmpty else { return }
        dwell?.cancel()
        isPeeking = false
        advance()
    }

    /// Bring a specific stranded prompt back, rather than whatever is at the
    /// head of the queue.
    func resurface(_ prompt: Prompt) {
        guard current == nil, let index = waiting.firstIndex(where: { $0.id == prompt.id }) else { return }
        dwell?.cancel()
        isPeeking = false
        let chosen = waiting.remove(at: index)
        waitingCount = waiting.count
        present(chosen)
    }

    // MARK: Hover peek

    /// The pointer entered or left the notch sensor.
    func hoverChanged(_ hovering: Bool) {
        pointerOnSensor = hovering
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
        guard current == nil, !isPeeking else { return }
        isPeeking = true
        onVisibilityChange?(true)
    }

    /// The pointer entered or left the expanded panel.
    func peekHoverChanged(_ hovering: Bool) {
        pointerOnPanel = hovering
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
            // A real blocked prompt outranks the idle surface.
            guard current == nil, !isPeeking else { return }
            // Short enough to feel immediate, long enough that crossing the
            // notch on the way somewhere else doesn't trigger it. The sensor is
            // only the notch itself, and nothing else lives there, so this can
            // be far tighter than a menu-bar hot corner would allow.
            dwell = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.peekDelayMilliseconds))
                guard !Task.isCancelled, let self, current == nil else { return }
                isPeeking = true
                onVisibilityChange?(true)
            }
        } else {
            guard isPeeking else { return }
            dwell = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.peekCloseGraceMilliseconds))
                guard !Task.isCancelled, let self else { return }
                isPeeking = false
                onVisibilityChange?(current != nil)
            }
        }
    }

    func endPeek() {
        dwell?.cancel()
        guard isPeeking else { return }
        isPeeking = false
        onVisibilityChange?(current != nil)
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
        dwell?.cancel()
        isPeeking = false
        onVisibilityChange?(false)
    }

    // MARK: Private

    private func present(_ prompt: Prompt) {
        // A prompt always wins over the idle surface.
        dwell?.cancel()
        isPeeking = false
        current = prompt
        onVisibilityChange?(true)
    }

    private func advance() {
        if waiting.isEmpty {
            current = nil
            waitingCount = 0
            // Answering always collapses, even if the pointer is still over the
            // notch — re-opening into a peek the user didn't ask for reads as a
            // glitch rather than a feature. Another dwell brings it back.
            dwell?.cancel()
            isPeeking = false
            onVisibilityChange?(false)
        } else {
            let next = waiting.removeFirst()
            waitingCount = waiting.count
            present(next)
        }
    }
}
