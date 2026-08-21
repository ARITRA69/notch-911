//
//  AppModel.swift
//  notch-911
//
//  Wires the server, the queue and the panel together, and owns the spike's
//  visible state (port, connection status, event log).
//

import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import os

@MainActor
@Observable
final class AppModel {

    enum ServerState: Equatable {
        case starting
        case listening(UInt16)
        case failed(String)
    }

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let text: String
    }

    /// Shapes the status window can push through the notch without a live agent.
    enum SimulatedShape: String, CaseIterable, Identifiable {
        case permission = "Permission"
        case askQuestion = "Ask question"
        case singleSelect = "Single select"
        case multiSelect = "Multi select"
        case freeText = "Free text"

        var id: String { rawValue }
    }

    static let shared = AppModel()

    private(set) var serverState: ServerState = .starting
    private(set) var isConnected = false
    private(set) var isCodexConnected = false
    private(set) var accessibilityTrusted = CodexAccessibilityBridge.isTrusted
    private(set) var signatureStatus = CodeSignatureInspector.current()
    private(set) var setupError: String?
    private(set) var log: [LogEntry] = []

    /// §13 open question 1 — Stop fires on *every* turn end, which could be a
    /// lot of notch. Off unless the user asks for it.
    var surfaceStop: Bool {
        didSet {
            UserDefaults.standard.set(surfaceStop, forKey: "notchd.surfaceStop")
            reapplyRegistrations()
        }
    }

    /// Says "finished" when a turn ends, then gets out of the way.
    ///
    /// On by default, where `surfaceStop` is off, because the two do different
    /// things with the same signal. `surfaceStop` *blocks* the turn on a reply
    /// box — real cost, worth asking first. This only shows a banner for a few
    /// seconds and releases the hook immediately, so the cost of it being wrong
    /// is a few seconds of notch, and a completion notice nobody switched on is
    /// a completion notice nobody knows exists.
    var announceCompletion: Bool {
        didSet {
            UserDefaults.standard.set(announceCompletion, forKey: "notchd.announceCompletion")
            reapplyRegistrations()
            startCodexCompletionWatcher()
            if !announceCompletion { coordinator.dismissCompletion() }
            append(announceCompletion
                   ? "completion notices on"
                   : "completion notices off")
        }
    }

    /// Spotify and Music.app answer for themselves; YouTube Music only exists as
    /// a browser tab, so reading it means controlling the browser — every tab's
    /// URL — plus the browser's own "Allow JavaScript from Apple Events" switch.
    /// Too much to take without being asked, so it's opt-in.
    var youTubeMusic: Bool {
        didSet {
            UserDefaults.standard.set(youTubeMusic, forKey: MediaController.youTubeMusicDefaultsKey)
            append(youTubeMusic
                   ? "youtube music enabled — reads music.youtube.com tabs"
                   : "youtube music disabled")
        }
    }

    /// Capture is on by default — a clipboard history you must switch on before
    /// it records anything is empty exactly when you first go looking for it.
    /// The switch exists so it can be turned *off*.
    ///
    /// This is the one setting that departs from the house posture of opt-in.
    /// `surfaceStop` and `youTubeMusic` default off because they reach outward —
    /// rewriting hook config, scripting every browser tab. Clipboard capture is
    /// local, nothing leaves this Mac, and `ClipboardCapture.excludedTypes`
    /// covers the genuinely sensitive case.
    ///
    /// Turning it off stops capture but keeps what's already there; silently
    /// deleting history on a toggle is not a thing a toggle should do.
    var clipboardCapture: Bool {
        didSet {
            UserDefaults.standard.set(clipboardCapture, forKey: ClipboardStore.captureDefaultsKey)
            clipboard.setCapturing(clipboardCapture)
            append(clipboardCapture ? "clipboard capture on" : "clipboard capture off")
        }
    }

    /// Codex isn't installed everywhere; don't offer to wire up something absent.
    let isCodexInstalled = CodexSettings.isCodexInstalled()

    /// Whether ⇧⌘V registered. Not whether it *works* — a chord another app
    /// already owns registers successfully and then never fires, with no API to
    /// detect it — but a failed registration is worth surfacing.
    private(set) var isClipboardHotkeyRegistered = false
    private(set) var isVoiceHotkeyRegistered = false

    @ObservationIgnored let coordinator = PromptCoordinator()
    @ObservationIgnored let media = MediaMonitor()
    @ObservationIgnored let shelf = ShelfStore()
    @ObservationIgnored let clipboard = ClipboardStore()
    @ObservationIgnored let voice = VoiceNoteStore()
    @ObservationIgnored private var clipboardHotkey: GlobalHotkey?
    @ObservationIgnored private var voiceHotkey: GlobalHotkey?

    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var panelController: NotchPanelController?
    @ObservationIgnored private let codexQuestionWatcher = CodexPlanQuestionWatcher()
    @ObservationIgnored private let codexCompletionWatcher = CodexCompletionWatcher()
    @ObservationIgnored private let codexApprovalWatcher = CodexApprovalWatcher()
    @ObservationIgnored private let codexAccessibilityBridge: any CodexQuestionSubmitting = CodexAccessibilityBridge()
    @ObservationIgnored private var codexQuestionTask: Task<Void, Never>?
    @ObservationIgnored private var codexCompletionTask: Task<Void, Never>?
    @ObservationIgnored private var codexApprovalTask: Task<Void, Never>?
    /// Approval cards currently on screen, so a turn completion can retract
    /// them: a completed turn cannot still be waiting on an approval.
    @ObservationIgnored private var activeCodexApprovalIDs: Set<String> = []
    @ObservationIgnored private var codexSubmissionTimeouts: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var codexSubmissionCancellations: [String: CodexSubmissionCancellation] = [:]
    @ObservationIgnored
    private let logger = Logger(subsystem: "com.aritra360.notch-911", category: "AppModel")

    /// M0 only. §5.4 puts this in the Keychain, which lands in M3.
    @ObservationIgnored private let token: String = {
        let key = "notchd.token"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    /// Whether the `Stop` hook needs registering at all. Two unrelated features
    /// ride the same event, and it must stay registered while *either* wants
    /// it — deriving it from `surfaceStop` alone silently unregisters the hook
    /// out from under the completion banner.
    private var registersStopHook: Bool { surfaceStop || announceCompletion }

    /// Exact-match routing. `hasSuffix` would be ambiguous once Codex's paths
    /// share the `/notchd/` prefix.
    @ObservationIgnored
    private let routes: [(path: String, agent: Agent, event: HookEventKind)] = [
        (ClaudeSettings.permissionPath, .claudeCode, .permissionRequest),
        (ClaudeSettings.elicitationPath, .claudeCode, .elicitation),
        (ClaudeSettings.stopPath, .claudeCode, .stop),
        (CodexSettings.permissionPath, .codex, .permissionRequest),
        (CodexSettings.stopPath, .codex, .stop),
    ]

    private init() {
        // `UserDefaults.bool(forKey:)` answers false for an unset key, so a
        // default of *on* has to be registered rather than assumed.
        UserDefaults.standard.register(defaults: [ClipboardStore.captureDefaultsKey: true])
        UserDefaults.standard.register(defaults: ["notchd.announceCompletion": true])
        surfaceStop = UserDefaults.standard.bool(forKey: "notchd.surfaceStop")
        announceCompletion = UserDefaults.standard.bool(forKey: "notchd.announceCompletion")
        youTubeMusic = UserDefaults.standard.bool(forKey: MediaController.youTubeMusicDefaultsKey)
        clipboardCapture = UserDefaults.standard.bool(forKey: ClipboardStore.captureDefaultsKey)
    }

    var port: UInt16? {
        if case .listening(let port) = serverState { return port }
        return nil
    }

    var manualSnippet: String {
        ClaudeSettings.manualSnippet(port: port ?? 8917, token: token)
    }

    // MARK: Lifecycle

    func start() {
        // §6.1 geometry is read at runtime and never hardcoded, so log what we
        // actually resolved — a wrong inset silently picks the pill fallback.
        if let screen = NotchGeometry.screen() {
            append(
                "display \(Int(screen.frame.width))×\(Int(screen.frame.height)) · "
                + "notch inset \(NotchGeometry.inset)pt · "
                + "notch width \(Int(NotchGeometry.notchWidth(on: screen)))pt · "
                + (NotchGeometry.hasNotch ? "notched" : "pill fallback")
            )
        }
        panelController = NotchPanelController(
            coordinator: coordinator,
            media: media,
            shelf: shelf,
            clipboard: clipboard,
            voice: voice
        )
        // Visibility is no longer just "is there a prompt": the collapsed mini
        // player has to keep the panel on screen whenever music is playing.
        coordinator.onVisibilityChange = { [weak self] _ in
            self?.refreshPanelVisibility()
        }
        coordinator.onPeekChange = { [weak self] active in
            self?.media.setPeekOpen(active)
        }
        coordinator.onSubmitExternal = { [weak self] prompt, answers in
            self?.submitCodexQuestion(prompt, answers: answers)
        }
        coordinator.onExternalResolution = { [weak self] callID in
            self?.codexSubmissionTimeouts.removeValue(forKey: callID)?.cancel()
            self?.codexSubmissionCancellations.removeValue(forKey: callID)?.cancel()
        }
        media.onChange = { [weak self] in
            self?.refreshPanelVisibility()
        }
        // Both edges of the capture flash: bring the panel on screen for the
        // badge, and let it go again once the badge has left.
        clipboard.onCapture = { [weak self] in
            self?.refreshPanelVisibility()
        }
        // A note being recorded keeps the panel on screen for its collapsed
        // indicator, and tells the coordinator to leave the notch alone while
        // it's up — see `PromptCoordinator.voiceIsCapturing`.
        voice.onCaptureChange = { [weak self] in
            guard let self else { return }
            coordinator.voiceIsCapturing = voice.isCapturing
            refreshPanelVisibility()
        }
        media.start()
        clipboard.setCapturing(clipboardCapture)
        registerClipboardHotkey()
        registerVoiceHotkey()
        startCodexQuestionWatcher()
        startCodexCompletionWatcher()
        startCodexApprovalWatcher()
        coordinator.onExternalPermission = { [weak self] prompt, decision in
            self?.submitCodexApproval(prompt, decision: decision)
        }

        let server = HookServer(token: token) { [weak self] request in
            await self?.handle(request) ?? .noDecision
        }
        self.server = server

        Task {
            do {
                let port = try await server.start()
                serverState = .listening(port)
                append("listening on 127.0.0.1:\(port)")
                // Re-patch on every launch: the port can move if the preferred
                // range is contended, and a stale URL (or a stale port baked
                // into Codex's shim) means every hook silently fails open.
                reapplyRegistrations()
                isConnected = ClaudeSettings.isConnected()
                isCodexConnected = CodexSettings.isConnected()
                refreshStatus()
            } catch {
                serverState = .failed(error.localizedDescription)
                append("server failed: \(error.localizedDescription)")
            }
        }
    }

    func shutDown() {
        codexQuestionTask?.cancel()
        codexQuestionTask = nil
        codexCompletionTask?.cancel()
        codexCompletionTask = nil
        codexApprovalTask?.cancel()
        codexApprovalTask = nil
        for task in codexSubmissionTimeouts.values { task.cancel() }
        codexSubmissionTimeouts.removeAll()
        for cancellation in codexSubmissionCancellations.values { cancellation.cancel() }
        codexSubmissionCancellations.removeAll()
        coordinator.releaseAll()
        clipboardHotkey?.invalidate()
        clipboardHotkey = nil
        voiceHotkey?.invalidate()
        voiceHotkey = nil
        // A recording caught mid-quit is discarded, not transcribed and saved:
        // the app is on its way out and there is no surface left to show the
        // result on, and `cancel()` is the only one of the three stop paths
        // that doesn't kick off an async transcription task racing the process
        // teardown.
        voice.cancel()
        voice.stopPlayback()
        clipboard.flush()
        server?.stop()
    }

    /// Registered from `start()` and nowhere else, so it inherits the XCTest
    /// guard in `AppDelegate` — a test run that grabbed a system-wide chord
    /// would reach straight out of the test and into the developer's machine.
    private func registerClipboardHotkey() {
        // Carbon modifier masks, *not* `NSEvent.ModifierFlags` — different bit
        // layouts, and mixing them registers a chord nobody can type.
        clipboardHotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_V),
            carbonModifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.coordinator.toggleClipboard()
        }
        isClipboardHotkeyRegistered = clipboardHotkey != nil
        append(isClipboardHotkeyRegistered
               ? "⇧⌘V registered for clipboard history"
               : "⇧⌘V could not be registered — another app may already own it")
    }

    func clearClipboardHistory() {
        clipboard.removeAll()
        append("cleared clipboard history")
    }

    /// Registered from `start()` for the same reason the clipboard hotkey is —
    /// so a test run that grabbed a system-wide chord never reaches past the
    /// test into the developer's own Mac.
    private func registerVoiceHotkey() {
        voiceHotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_M),
            carbonModifiers: UInt32(cmdKey | shiftKey)
        ) { [weak self] in
            self?.toggleVoiceRecording()
        }
        isVoiceHotkeyRegistered = voiceHotkey != nil
        append(isVoiceHotkeyRegistered
               ? "⇧⌘M registered for voice notes"
               : "⇧⌘M could not be registered — another app may already own it")
    }

    /// One key, two jobs, matched to whether anything is currently listening —
    /// the same "toggle rather than open" shape ⇧⌘V uses for the clipboard,
    /// except here the second press has somewhere to go: `stop()` doesn't just
    /// close a picker, it hands back a note.
    func toggleVoiceRecording() {
        guard coordinator.current == nil else { return }
        if voice.isCapturing {
            voice.stop()
        } else {
            // Deliberately does *not* open the surface. Recording shows up as
            // the indicator in the collapsed notch and nothing else; the panel
            // only opens if the user clicks it to reach Discard / Pause / Save.
            // A hotkey you press mid-sentence should not throw a window up.
            voice.start()
        }
    }

    func clearVoiceNotes() {
        voice.removeAll()
        append("cleared voice notes")
    }

    // MARK: Hook handling

    private func handle(_ request: HookServer.Request) async -> HookServer.Response {
        guard let route = routes.first(where: { $0.path == request.path }) else {
            return HookServer.Response(status: 404)
        }

        guard let prompt = Prompt.make(agent: route.agent, event: route.event, body: request.body) else {
            // Fail open rather than leaving the session wedged on a payload
            // shape we don't recognise (§13, hook schema drift).
            append("could not decode \(route.event.rawValue) — falling through")
            return .noDecision
        }

        append("\(route.agent.displayName) · \(prompt.projectName): \(prompt.title.prefix(50))")

        // A finished turn is news, not a question, so it never joins the
        // waiting queue. Awaiting `coordinator.response` here would hold the
        // agent's `Stop` hook open for as long as the banner is on screen —
        // turning a notification into a four-second stall on every turn.
        //
        // `surfaceStop` wins when both are on: its reply box already says the
        // turn ended, and stacking a banner in front of it would cover the one
        // surface the user asked to be blocked by.
        if route.event == .stop, !surfaceStop {
            if announceCompletion {
                coordinator.announce(
                    CompletionNotice(
                        agent: route.agent,
                        cwd: prompt.cwd,
                        summary: prompt.summary
                    )
                )
            }
            return .noDecision
        }

        guard let response = await coordinator.response(to: prompt),
              let body = response.body(for: route.event)
        else {
            append(Task.isCancelled
                   ? "\(route.event.rawValue) resolved in the session — card retracted"
                   : "no decision on \(route.event.rawValue) — falling through")
            return .noDecision
        }

        append("answered \(route.event.rawValue)")
        return HookServer.Response(status: 200, body: body)
    }

    // MARK: Codex plan questions

    /// Codex App plan questions do not emit a lifecycle hook. Observe the
    /// unresolved `request_user_input` calls in its local task rollouts and
    /// remove cards when the matching output is persisted.
    /// Codex's turn-completion signal, taken from the same rollout logs the
    /// plan-question watcher reads.
    ///
    /// This exists because Codex's `Stop` hook does not fire — see the header
    /// of `CodexCompletionWatcher`. Kept as its own loop rather than folded
    /// into `startCodexQuestionWatcher` because it answers to a user setting
    /// the other doesn't: someone who turns completion notices off should stop
    /// paying for the directory scan, not just stop seeing the banner.
    private func startCodexCompletionWatcher() {
        codexCompletionTask?.cancel()
        guard announceCompletion, isCodexInstalled else { return }
        codexCompletionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                for completion in await codexCompletionWatcher.poll() {
                    if !activeCodexApprovalIDs.isEmpty {
                        let stale = Array(activeCodexApprovalIDs)
                        activeCodexApprovalIDs.removeAll()
                        for id in stale { coordinator.externalPromptResolved(id) }
                        await codexApprovalWatcher.resolveExternally(stale)
                    }
                    coordinator.announce(
                        CompletionNotice(
                            agent: .codex,
                            cwd: completion.cwd,
                            summary: completion.lastAgentMessage,
                            duration: completion.duration,
                            receivedAt: completion.completedAt
                        )
                    )
                    append("Codex · turn complete")
                }
                // Slower than the question watcher's 500ms. A question is
                // someone waiting on you and worth finding fast; a finished
                // turn a second late reads exactly the same.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Codex approval prompts, detected from Codex's rollout logs — the one
    /// channel visible from every Space; see `CodexApprovalWatcher`'s header.
    /// Detection needs no permission at all; only *answering* touches
    /// Accessibility, over in `submitCodexApproval`.
    private func startCodexApprovalWatcher() {
        codexApprovalTask?.cancel()
        guard isCodexInstalled else { return }
        codexApprovalTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let changes = await codexApprovalWatcher.poll()
                for id in changes.resolvedIDs {
                    activeCodexApprovalIDs.remove(id)
                    coordinator.externalPromptResolved(id)
                }
                for approval in changes.appeared {
                    activeCodexApprovalIDs.insert(approval.callID)
                    let prompt = Prompt(
                        agent: .codex,
                        event: .permissionRequest,
                        sessionId: approval.sessionID,
                        cwd: approval.cwd,
                        title: approval.question,
                        summary: "",
                        kind: .permission,
                        receivedAt: approval.receivedAt,
                        externalID: approval.callID
                    )
                    coordinator.observe(prompt)
                    append("Codex · approval: \(approval.question.prefix(50))")
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startCodexQuestionWatcher() {
        codexQuestionTask?.cancel()
        codexQuestionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let changes = await codexQuestionWatcher.poll()
                accessibilityTrusted = CodexAccessibilityBridge.isTrusted
                for callID in changes.resolvedCallIDs {
                    coordinator.externalPromptResolved(callID)
                }
                for question in changes.appeared {
                    guard let first = question.questions.first else { continue }
                    let prompt = Prompt(
                        agent: .codex,
                        event: .userInputRequest,
                        sessionId: question.sessionID,
                        cwd: question.cwd,
                        title: first.question,
                        summary: "",
                        kind: .externalQuestion,
                        receivedAt: question.receivedAt,
                        externalID: question.callID,
                        codexQuestions: question.questions
                    )
                    coordinator.observe(prompt)
                    append("Codex · \(prompt.projectName): plan question")
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func enableAccessibility() {
        accessibilityTrusted = CodexAccessibilityBridge.requestTrust()
        if !accessibilityTrusted,
           let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(settings)
        }
        append(accessibilityTrusted
               ? "Accessibility enabled for direct Codex answers"
               : "Accessibility permission requested")
    }

    /// Presses the real Allow/Deny in the Codex window. The card is already
    /// resolved by the time this runs — fire-and-forget, with one fallback:
    /// when the window is on another Space the press cannot land there, so
    /// Codex is activated (which brings its Space forward) and the press is
    /// retried while the window becomes visible to Accessibility.
    private func submitCodexApproval(_ prompt: Prompt, decision: PermissionDecision) {
        guard let externalID = prompt.externalID else { return }
        activeCodexApprovalIDs.remove(externalID)
        let question = prompt.title
        Task { [weak self] in
            guard let self else { return }
            let allow = decision == .allow
            if await codexApprovalWatcher.press(question: question, allow: allow) {
                append("Codex · approval \(decision.rawValue) pressed")
                return
            }
            append("Codex · approval press blocked — bringing Codex forward")
            // The trip to Codex is not optional: macOS hides other Spaces'
            // windows from Accessibility, so the button can only be pressed
            // while Codex's Space is frontmost. What *is* optional is
            // stranding the user there — remember where they were, make the
            // trip, and put them back.
            let cameFrom = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            // Not `NSRunningApplication.activate`: macOS's cooperative
            // activation rules silently deny focus changes requested by a
            // background app, and this panel never becomes the active app even
            // when clicked. Telling an app to activate *itself* over Apple
            // Events is the one route that is always honoured — the same
            // out-of-process `osascript` pattern `MediaController` uses. First
            // use asks the user to allow notch-911 to control each app.
            Self.activateApp(bundleID: CodexApprovalWatcher.bundleID)
            var landed = false
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(400))
                if await codexApprovalWatcher.press(question: question, allow: allow) {
                    landed = true
                    break
                }
            }
            append(landed
                   ? "Codex · approval \(decision.rawValue) pressed after activation"
                   : "Codex · approval press failed — answer in the Codex window")
            // Return only after a successful press. A failed press means the
            // prompt still needs the user's eyes, and yanking them away from
            // it would hide the very thing they have to deal with.
            if landed, let cameFrom, cameFrom != CodexApprovalWatcher.bundleID {
                try? await Task.sleep(for: .milliseconds(400))
                Self.activateApp(bundleID: cameFrom)
            }
        }
    }

    /// Self-activation over Apple Events — the only focus-change request
    /// modern macOS reliably honours from a background app.
    private static func activateApp(bundleID: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application id \"\(bundleID)\" to activate"]
        try? process.run()
    }

    private func submitCodexQuestion(_ prompt: Prompt, answers: [CodexQuestionAnswer]) {
        guard let callID = prompt.externalID else { return }
        accessibilityTrusted = CodexAccessibilityBridge.isTrusted
        guard accessibilityTrusted else {
            coordinator.setExternalSubmissionState(.requestingPermission, for: callID)
            enableAccessibility()
            if !accessibilityTrusted {
                coordinator.setExternalSubmissionState(
                    .failed("Enable notch-911 in Privacy & Security → Accessibility, then press Send again."),
                    for: callID
                )
            }
            return
        }

        guard let processID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first?.processIdentifier else {
            coordinator.setExternalSubmissionState(.failed("Codex is not running."), for: callID)
            return
        }

        coordinator.setExternalSubmissionState(.submitting, for: callID)
        let questions = prompt.codexQuestions
        let bridge = codexAccessibilityBridge
        codexSubmissionCancellations.removeValue(forKey: callID)?.cancel()
        let cancellation = CodexSubmissionCancellation()
        codexSubmissionCancellations[callID] = cancellation
        Task { [weak self] in
            let result: Result<Void, CodexAccessibilityError> = await Task.detached {
                do {
                    try bridge.submit(
                        to: processID,
                        questions: questions,
                        answers: answers,
                        cancellation: cancellation
                    )
                    return .success(())
                } catch let error as CodexAccessibilityError {
                    return .failure(error)
                } catch {
                    return .failure(.actionFailed("Send"))
                }
            }.value

            guard let self,
                  coordinator.isExternalPromptActive(callID),
                  codexSubmissionCancellations[callID] === cancellation
            else { return }
            codexSubmissionCancellations.removeValue(forKey: callID)
            switch result {
            case .success:
                codexSubmissionTimeouts[callID]?.cancel()
                codexSubmissionTimeouts[callID] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self,
                          coordinator.isExternalPromptActive(callID),
                          coordinator.externalSubmissionState(for: prompt) == .submitting
                    else { return }
                    coordinator.setExternalSubmissionState(
                        .failed("Codex did not confirm the answer. Open Codex to finish it safely."),
                        for: callID
                    )
                    codexSubmissionTimeouts.removeValue(forKey: callID)
                }
            case .failure(let error):
                coordinator.setExternalSubmissionState(
                    .failed(error.localizedDescription),
                    for: callID
                )
            }
        }
    }

    // MARK: Setup

    func connect() {
        guard let port else { return }
        do {
            try ClaudeSettings.connect(port: port, token: token, includeStop: registersStopHook)
            isConnected = true
            setupError = nil
            refreshStatus()
            append("registered Claude Code hooks on port \(port)")
        } catch {
            setupError = error.localizedDescription
            append("connect failed: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        do {
            try ClaudeSettings.disconnect()
            isConnected = false
            setupError = nil
            refreshStatus()
            append("removed hooks from ~/.claude/settings.json")
        } catch {
            setupError = error.localizedDescription
            append("disconnect failed: \(error.localizedDescription)")
        }
    }

    func connectCodex() {
        guard let port else { return }
        do {
            try CodexSettings.connect(port: port, token: token, includeStop: registersStopHook)
            isCodexConnected = true
            setupError = nil
            refreshStatus()
            append("registered Codex hooks on port \(port)")
        } catch {
            setupError = error.localizedDescription
            append("codex connect failed: \(error.localizedDescription)")
        }
    }

    func disconnectCodex() {
        do {
            try CodexSettings.disconnect()
            isCodexConnected = false
            setupError = nil
            refreshStatus()
            append("removed hooks from ~/.codex/hooks.json")
        } catch {
            setupError = error.localizedDescription
            append("codex disconnect failed: \(error.localizedDescription)")
        }
    }

    /// The panel stays on screen for a prompt, for the peek, for the collapsed
    /// mini player, or for the moment a copy is being acknowledged — anything
    /// else orders it out.
    private func refreshPanelVisibility() {
        panelController?.setVisible(
            coordinator.isInteractive
                || media.nowPlaying != nil
                || clipboard.justCaptured
                || voice.isBusy
        )
    }

    /// Pushes connection state down to the coordinator so the hover-peek can
    /// report it without reaching back up into the app model.
    private func refreshStatus() {
        coordinator.agentStatus = .init(
            claudeConnected: isConnected,
            codexConnected: isCodexConnected,
            port: port
        )
    }

    /// Rewrites whichever registrations already exist, so a port change or a
    /// Stop toggle takes effect without the user touching anything.
    private func reapplyRegistrations() {
        guard let port else { return }
        do {
            if ClaudeSettings.isConnected() {
                try ClaudeSettings.connect(port: port, token: token, includeStop: registersStopHook)
            }
            if CodexSettings.isConnected() {
                try CodexSettings.connect(port: port, token: token, includeStop: registersStopHook)
            }
        } catch {
            setupError = error.localizedDescription
        }
    }

    // MARK: Spike affordances

    /// Drives the panel without needing a live agent session. Not shipped.
    func simulate(_ shape: SimulatedShape, agent: Agent = .claudeCode) {
        let prompt: Prompt
        switch shape {
        case .permission:
            prompt = Prompt(
                agent: agent,
                event: .permissionRequest,
                sessionId: UUID().uuidString,
                cwd: FileManager.default.currentDirectoryPath,
                title: agent == .codex ? "shell" : "Bash",
                summary: "rm -rf node_modules && npm install",
                kind: .permission,
                receivedAt: Date()
            )

        case .askQuestion:
            prompt = Prompt(
                agent: agent,
                event: .permissionRequest,
                sessionId: UUID().uuidString,
                cwd: FileManager.default.currentDirectoryPath,
                title: "Which areas should I focus on?",
                summary: "",
                kind: .question([
                    AskQuestion(
                        id: 0,
                        header: "Focus",
                        question: "Which areas should I focus on?",
                        multiSelect: true,
                        options: [
                            AskOption(label: "Correctness", detail: "Bugs and edge cases first."),
                            AskOption(label: "Performance", detail: "Speed and memory."),
                            AskOption(label: "Readability", detail: "Naming and structure."),
                        ]
                    ),
                    AskQuestion(
                        id: 1,
                        header: "Tests",
                        question: "Should I add tests as I go?",
                        multiSelect: false,
                        options: [
                            AskOption(label: "Yes", detail: nil),
                            AskOption(label: "Only for fixes", detail: nil),
                        ]
                    ),
                ]),
                receivedAt: Date()
            )

        case .singleSelect:
            prompt = Prompt(
                agent: agent,
                event: .elicitation,
                sessionId: UUID().uuidString,
                cwd: FileManager.default.currentDirectoryPath,
                title: "Which database should I wire up?",
                summary: "",
                kind: .form([
                    FormField(
                        name: "database",
                        title: "Database",
                        detail: "Used for the new persistence layer.",
                        isRequired: true,
                        input: .singleSelect([
                            Choice(value: "postgres", label: "PostgreSQL"),
                            Choice(value: "sqlite", label: "SQLite"),
                            Choice(value: "mongo", label: "MongoDB"),
                        ])
                    ),
                    FormField(
                        name: "notes",
                        title: "Anything else I should know?",
                        detail: nil,
                        isRequired: false,
                        input: .text(placeholder: "Optional")
                    ),
                ]),
                receivedAt: Date()
            )

        case .multiSelect:
            prompt = Prompt(
                agent: agent,
                event: .elicitation,
                sessionId: UUID().uuidString,
                cwd: FileManager.default.currentDirectoryPath,
                title: "Which checks should run before deploy?",
                summary: "",
                kind: .form([
                    FormField(
                        name: "checks",
                        title: "Pre-deploy checks",
                        detail: "Pick as many as apply.",
                        isRequired: true,
                        input: .multiSelect([
                            Choice(value: "unit", label: "Unit tests"),
                            Choice(value: "lint", label: "Lint"),
                            Choice(value: "types", label: "Type check"),
                            Choice(value: "e2e", label: "End-to-end tests"),
                        ])
                    ),
                    FormField(
                        name: "block_on_failure",
                        title: "Block the deploy on failure",
                        detail: nil,
                        isRequired: false,
                        input: .toggle
                    ),
                    FormField(
                        name: "notes",
                        title: "Notes",
                        detail: nil,
                        isRequired: false,
                        input: .text(placeholder: "Optional")
                    ),
                ]),
                receivedAt: Date()
            )

        case .freeText:
            prompt = Prompt(
                agent: agent,
                event: .stop,
                sessionId: UUID().uuidString,
                cwd: FileManager.default.currentDirectoryPath,
                title: "Anything else?",
                summary: "I've finished wiring up the hook server and both connectors.",
                kind: .freeText(placeholder: "Reply to continue, or dismiss to end the turn"),
                receivedAt: Date()
            )
        }

        Task {
            let response = await coordinator.response(to: prompt)
            append("simulated \(shape.rawValue) → \(describe(response))")
        }
    }

    private func describe(_ response: PromptResponse?) -> String {
        switch response {
        case .none: return "no decision"
        case .permission(let decision): return decision.rawValue
        case .answers(let answers):
            return "answered \(answers.count) question\(answers.count == 1 ? "" : "s")"
        case .form(let action, let values):
            return values.isEmpty ? action.rawValue : "\(action.rawValue) \(values.keys.sorted())"
        case .text(let text):
            return text.isEmpty ? "end turn" : "reply: \(text.prefix(40))"
        }
    }

    private func append(_ text: String) {
        logger.info("\(text, privacy: .public)")
        log.append(LogEntry(at: Date(), text: text))
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }
}
