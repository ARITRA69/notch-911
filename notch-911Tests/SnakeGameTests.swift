//
//  SnakeGameTests.swift
//  notch-911Tests
//
//  The board is pure, deterministic state behind a clock, so the thing worth
//  pinning is the clock: closing the notch has to stop it *now*, not whenever
//  SwiftUI gets round to unmounting the view.
//

import Foundation
import Testing
@testable import notch_911

@Suite("Snake game")
@MainActor
struct SnakeGameTests {

    /// Comfortably longer than the 150ms opening interval, so a loop that is
    /// still alive is guaranteed to have landed at least one step.
    private static let longerThanATick = Duration.milliseconds(400)

    @Test("A closed board stops stepping immediately")
    func stoppingHaltsTheLoop() async {
        let game = SnakeGame()
        // `reset()` bumps the counter once to force the first draw, so measure
        // from where construction left it rather than from zero.
        let atRest = game.frame
        game.setRunning(true)
        game.turn(.right)

        // Let it actually tick, so the test is proving the loop stopped rather
        // than that it never started.
        try? await Task.sleep(for: Self.longerThanATick)
        #expect(game.frame > atRest)

        game.setRunning(false)
        #expect(game.isRunning == false)

        // `stop()` itself was never the bug — it was called too late, from the
        // view's `onDisappear`, which the 800ms collapse delays. What this pins
        // is the property the fix depends on: stopping takes effect on the call,
        // so moving the call earlier is sufficient. The predicate that decides
        // *when* to call it is covered by `gameLiveness` and `promptStopsTheBoard`
        // below; the one line wiring them together lives in a SwiftUI view and is
        // out of reach of a unit test.
        let frameAtClose = game.frame
        try? await Task.sleep(for: Self.longerThanATick)
        #expect(game.frame == frameAtClose)
    }

    @Test("Closing mid-run cannot bank a worse high score")
    func closingDoesNotBankAScore() async {
        let key = SnakeGame.highScoreDefaultsKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // A best worth protecting, then a fresh board that will never beat it.
        UserDefaults.standard.set(99, forKey: key)
        let game = SnakeGame()
        #expect(game.best == 99)

        game.setRunning(true)
        game.turn(.right)
        game.setRunning(false)

        // Steering into the wall off-screen was how the old bug ended the run.
        try? await Task.sleep(for: Self.longerThanATick)
        #expect(game.phase != .over)
        #expect(UserDefaults.standard.integer(forKey: key) == 99)
    }

    @Test("Running the board twice does not start a second loop")
    func startingIsIdempotent() async {
        let game = SnakeGame()
        let atRest = game.frame
        game.setRunning(true)
        game.setRunning(true)
        game.turn(.right)

        try? await Task.sleep(for: Self.longerThanATick)
        let steps = game.frame - atRest
        game.setRunning(false)

        // Two loops on one board would roughly double the step rate. 400ms at
        // the 150ms opening interval is two or three steps; six leaves room for
        // a slow machine without admitting a doubled rate.
        #expect(steps > 0)
        #expect(steps <= 6)
    }

    @Test("Stopping a board that never ran is harmless")
    func stoppingIsIdempotent() async {
        let game = SnakeGame()
        let atRest = game.frame
        game.setRunning(false)
        game.setRunning(false)
        #expect(game.isRunning == false)

        try? await Task.sleep(for: Self.longerThanATick)
        #expect(game.frame == atRest)
    }

    /// Guards the predicate the panel drives `setRunning` from. The board is
    /// live only when it is the surface *and* nothing has taken the notch.
    @Test("Only an unpreempted game surface is live", arguments: IdleSurface.allCases)
    func gameLiveness(_ surface: IdleSurface) {
        let coordinator = PromptCoordinator()
        coordinator.reelsEnabled = true
        switch surface {
        case .clipboard: coordinator.openClipboard()
        case .game: coordinator.openGame()
        case .reels: coordinator.openReels()
        case .voice: coordinator.openVoice()
        case .mirror: coordinator.openMirror()
        case .peek, .none: break
        }
        guard surface != .peek else { return }
        #expect(coordinator.isGameLive == (surface == .game))
    }

    @Test("A prompt takes the board off the clock")
    func promptStopsTheBoard() async throws {
        let coordinator = PromptCoordinator()
        coordinator.openGame()
        #expect(coordinator.isGameLive)

        let prompt = Prompt(
            agent: .claudeCode, event: .permissionRequest, sessionId: "s", cwd: "/tmp/p",
            title: "Bash", summary: "ls", kind: .permission, receivedAt: Date()
        )
        let task = Task { await coordinator.response(to: prompt) }
        while coordinator.current == nil { await Task.yield() }

        #expect(coordinator.isGameLive == false)

        coordinator.resolve(prompt, with: .permission(.allow))
        _ = await task.value
        // The board does not come back — unlike the reels, it paused where it
        // stood and reopening resumes it.
        #expect(coordinator.idleSurface == .none)
    }
}
