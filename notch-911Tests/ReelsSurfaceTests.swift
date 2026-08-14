//
//  ReelsSurfaceTests.swift
//  notch-911Tests
//
//  The reels surface is mostly WebKit, which is not worth faking. What *is*
//  testable is the part that decides when the surface is on screen — the
//  preemption memo — and the scope gate. Both are pure state, so none of this
//  touches a web view.
//

import Foundation
import Testing
@testable import notch_911

@Suite("Reels surface")
@MainActor
struct ReelsSurfaceTests {

    // MARK: Helpers

    private func makeCoordinator() -> PromptCoordinator {
        let coordinator = PromptCoordinator()
        coordinator.reelsEnabled = true
        return coordinator
    }

    private func makePrompt(_ title: String) -> Prompt {
        Prompt(
            agent: .claudeCode,
            event: .permissionRequest,
            sessionId: "s",
            cwd: "/tmp/p",
            title: title,
            summary: "",
            kind: .permission,
            receivedAt: Date()
        )
    }

    /// Drives a prompt to the front the way `HookHangupTests` does — through the
    /// real blocked-response path, so the test exercises `present()` rather than
    /// a shortcut around it.
    private func present(
        _ prompt: Prompt,
        on coordinator: PromptCoordinator
    ) async -> Task<PromptResponse?, Never> {
        let task = Task { await coordinator.response(to: prompt) }
        while coordinator.current?.id != prompt.id { await Task.yield() }
        return task
    }

    // MARK: Which surfaces come back

    @Test("Only the reels survive being preempted", arguments: IdleSurface.allCases)
    func survivesPreemption(_ surface: IdleSurface) {
        #expect(surface.survivesPreemption == (surface == .reels))
    }

    /// Guards the allowlist at `wantsKeyboard`. Adding a case to `IdleSurface`
    /// and forgetting it there is a silent bug — the panel never becomes key and
    /// the surface simply never receives a keystroke — so it is pinned here for
    /// the next surface as much as for this one.
    @Test("Every idle surface declares its keyboard and hit-testing needs",
          arguments: IdleSurface.allCases)
    func surfaceCapabilities(_ surface: IdleSurface) {
        let coordinator = makeCoordinator()
        switch surface {
        case .clipboard: coordinator.openClipboard()
        case .game: coordinator.openGame()
        case .reels: coordinator.openReels()
        case .voice: coordinator.openVoice()
        case .mirror: coordinator.openMirror()
        case .peek, .none: break
        }
        guard surface != .peek else { return }

        #expect(coordinator.idleSurface == surface)
        #expect(coordinator.isInteractive == (surface != .none))
        // A peek may never take the keyboard; every surface you reach on purpose
        // must be able to.
        #expect(coordinator.wantsKeyboard == (surface != .none))
        #expect(coordinator.isReelsLive == (surface == .reels))
    }

    // MARK: The memo

    @Test("A prompt hands the reels back once it is answered")
    func promptRestoresReels() async throws {
        let coordinator = makeCoordinator()
        coordinator.openReels()
        #expect(coordinator.idleSurface == .reels)

        let prompt = makePrompt("Bash")
        let task = await present(prompt, on: coordinator)
        // The prompt owns the notch while it is up.
        #expect(coordinator.idleSurface == .none)
        #expect(coordinator.isReelsLive == false)

        coordinator.resolve(prompt, with: .permission(.allow))
        _ = await task.value

        #expect(coordinator.current == nil)
        #expect(coordinator.idleSurface == .reels)
        #expect(coordinator.isReelsLive)
    }

    @Test("A queued second prompt holds the reels back until the queue drains")
    func queuedPromptDefersRestore() async throws {
        let coordinator = makeCoordinator()
        coordinator.openReels()

        let first = makePrompt("Bash")
        let second = makePrompt("Write")
        let firstTask = await present(first, on: coordinator)
        let secondTask = Task { await coordinator.response(to: second) }
        while coordinator.waitingCount == 0 { await Task.yield() }

        coordinator.resolve(first, with: .permission(.allow))
        _ = await firstTask.value
        // Second is up now, so the notch stays its own.
        #expect(coordinator.current?.id == second.id)
        #expect(coordinator.idleSurface == .none)

        coordinator.resolve(second, with: .permission(.deny))
        _ = await secondTask.value
        #expect(coordinator.idleSurface == .reels)
    }

    @Test("Dismissing a prompt with esc does not reopen the reels")
    func escapeClearsTheMemo() async throws {
        let coordinator = makeCoordinator()
        coordinator.openReels()

        let prompt = makePrompt("Bash")
        let task = await present(prompt, on: coordinator)
        // `esc` means get out of my way — taken literally.
        coordinator.dismissCurrent()
        #expect(coordinator.idleSurface == .none)

        coordinator.resurface()
        coordinator.resolve(prompt, with: .permission(.allow))
        _ = await task.value
        #expect(coordinator.idleSurface == .none)
    }

    @Test("Surfaces that do not survive preemption stay closed", arguments: [
        IdleSurface.clipboard, .game,
    ])
    func otherSurfacesDoNotRestore(_ surface: IdleSurface) async throws {
        let coordinator = makeCoordinator()
        switch surface {
        case .clipboard: coordinator.openClipboard()
        default: coordinator.openGame()
        }

        let prompt = makePrompt("Bash")
        let task = await present(prompt, on: coordinator)
        coordinator.resolve(prompt, with: .permission(.allow))
        _ = await task.value

        #expect(coordinator.idleSurface == .none)
    }

    @Test("Disabling the feature mid-prompt cancels the restore")
    func disablingCancelsRestore() async throws {
        let coordinator = makeCoordinator()
        coordinator.openReels()

        let prompt = makePrompt("Bash")
        let task = await present(prompt, on: coordinator)
        coordinator.reelsEnabled = false

        coordinator.resolve(prompt, with: .permission(.allow))
        _ = await task.value
        #expect(coordinator.idleSurface == .none)
    }

    @Test("A surface the user opens themselves is not treated as preempted")
    func userDrivenChangeRetiresTheMemo() async throws {
        let coordinator = makeCoordinator()
        coordinator.openReels()
        // Walking back to the peek is the user closing the reels, not a prompt
        // taking them — so nothing should come back later.
        coordinator.backToPeek()
        #expect(coordinator.idleSurface == .peek)

        let prompt = makePrompt("Bash")
        let task = await present(prompt, on: coordinator)
        coordinator.resolve(prompt, with: .permission(.allow))
        _ = await task.value
        #expect(coordinator.idleSurface == .none)
    }

    @Test("Reels cannot be opened while the feature is off")
    func disabledSurfaceCannotOpen() {
        let coordinator = PromptCoordinator()
        coordinator.openReels()
        #expect(coordinator.idleSurface == .none)
    }

    // MARK: Scope

    @Test("Hosts inside Instagram's world are allowed", arguments: [
        "https://www.instagram.com/reels/",
        "https://instagram.com/",
        "https://i.instagram.com/api/v1/",
        "https://scontent.cdninstagram.com/v/video.mp4",
        "https://m.facebook.com/dialog/oauth",
        "https://static.xx.fbcdn.net/rsrc.php/script.js",
    ])
    func allowsInstagram(_ raw: String) throws {
        #expect(ReelsPolicy.isInside(try #require(URL(string: raw))))
    }

    @Test("Everything else is refused", arguments: [
        // Label-wise matching is the whole point: a `hasSuffix` on the bare
        // domain would wave both of these through.
        "https://evil-instagram.com/reels/",
        "https://instagram.com.attacker.net/login",
        "https://example.com/",
        // Plain HTTP is refused even for a domain that is otherwise in scope.
        "http://www.instagram.com/reels/",
        "javascript:alert(1)",
    ])
    func refusesEverythingElse(_ raw: String) throws {
        #expect(ReelsPolicy.isInside(try #require(URL(string: raw))) == false)
    }

    @Test("The start URL passes the surface's own gate")
    func startIsInScope() {
        #expect(ReelsPolicy.isInside(ReelsPolicy.start))
    }
}
