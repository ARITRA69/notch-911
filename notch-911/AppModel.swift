//
//  AppModel.swift
//  notch-911
//
//  Wires the server, the queue and the panel together, and owns the spike's
//  visible state (port, connection status, event log).
//

import AppKit
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

    /// Codex isn't installed everywhere; don't offer to wire up something absent.
    let isCodexInstalled = CodexSettings.isCodexInstalled()

    @ObservationIgnored let coordinator = PromptCoordinator()
    @ObservationIgnored let media = MediaMonitor()
    @ObservationIgnored let shelf = ShelfStore()

    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var panelController: NotchPanelController?
    @ObservationIgnored private let codexQuestionWatcher = CodexPlanQuestionWatcher()
    @ObservationIgnored private let codexAccessibilityBridge: any CodexQuestionSubmitting = CodexAccessibilityBridge()
    @ObservationIgnored private var codexQuestionTask: Task<Void, Never>?
    @ObservationIgnored private var codexSubmissionTimeouts: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var codexSubmissionCancellations: [String: CodexSubmissionCancellation] = [:]
    @ObservationIgnored
    private let logger = Logger(subsystem: "com.aritra69.notch-911", category: "AppModel")

    /// M0 only. §5.4 puts this in the Keychain, which lands in M3.
    @ObservationIgnored private let token: String = {
        let key = "notchd.token"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

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
        surfaceStop = UserDefaults.standard.bool(forKey: "notchd.surfaceStop")
        youTubeMusic = UserDefaults.standard.bool(forKey: MediaController.youTubeMusicDefaultsKey)
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
        panelController = NotchPanelController(coordinator: coordinator, media: media, shelf: shelf)
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
        media.start()
        startCodexQuestionWatcher()

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
        for task in codexSubmissionTimeouts.values { task.cancel() }
        codexSubmissionTimeouts.removeAll()
        for cancellation in codexSubmissionCancellations.values { cancellation.cancel() }
        codexSubmissionCancellations.removeAll()
        coordinator.releaseAll()
        server?.stop()
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
            try ClaudeSettings.connect(port: port, token: token, includeStop: surfaceStop)
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
            try CodexSettings.connect(port: port, token: token, includeStop: surfaceStop)
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

    /// The panel stays on screen for a prompt, for the peek, or for the
    /// collapsed mini player — anything else orders it out.
    private func refreshPanelVisibility() {
        panelController?.setVisible(
            coordinator.current != nil || coordinator.isPeeking || media.nowPlaying != nil
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
                try ClaudeSettings.connect(port: port, token: token, includeStop: surfaceStop)
            }
            if CodexSettings.isConnected() {
                try CodexSettings.connect(port: port, token: token, includeStop: surfaceStop)
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
