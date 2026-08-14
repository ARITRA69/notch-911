//
//  SnakeGame.swift
//  notch-911
//
//  Snake, on a 20×13 grid.
//
//  Everything here is integers on a lattice. There is no physics, no
//  interpolation and no frame loop: the board only changes when the snake takes
//  a step, so the game ticks eight to fourteen times a second and the surface
//  redraws exactly that often. That is two orders of magnitude less work than a
//  scrolling platformer, and it is why the game can sit in a background utility
//  without the utility having to apologise for it.
//
//  The one piece of bookkeeping worth naming is `occupied`: the body is an
//  array because order matters (head at 0, tail at the end), but collision has
//  to be O(1) or a long snake would cost a linear scan every step, so the same
//  cells are mirrored into a set.
//

import Foundation
import Observation

// MARK: - Grid

nonisolated struct SnakeCell: Hashable, Sendable {
    var x: Int
    var y: Int
}

nonisolated enum SnakeDirection: Sendable {
    case up, down, left, right

    var step: SnakeCell {
        switch self {
        case .up: SnakeCell(x: 0, y: -1)
        case .down: SnakeCell(x: 0, y: 1)
        case .left: SnakeCell(x: -1, y: 0)
        case .right: SnakeCell(x: 1, y: 0)
        }
    }

    /// A snake cannot reverse into itself, so a turn straight back the way it
    /// came is dropped rather than treated as an instant death.
    func reverses(_ other: SnakeDirection) -> Bool {
        switch (self, other) {
        case (.up, .down), (.down, .up), (.left, .right), (.right, .left): true
        default: false
        }
    }
}

// MARK: - Game

@MainActor
@Observable
final class SnakeGame {

    enum Phase {
        /// Waiting on the first input, so the board is readable before it moves.
        case ready
        case playing
        case over
    }

    static let columns = 20
    static let rows = 13

    /// Milliseconds per step at the start, and the floor it speeds up to. The
    /// board is only twenty cells wide — much faster than 70ms and a turn taken
    /// at the wall arrives after the wall does.
    private static let openingInterval = 150
    private static let fastestInterval = 72

    static let highScoreDefaultsKey = "notchd.snake.highScore"

    private(set) var body: [SnakeCell] = []
    private(set) var food = SnakeCell(x: 0, y: 0)
    private(set) var score = 0
    private(set) var best = 0
    private(set) var phase: Phase = .ready
    /// Ticks up every step so the canvas has something to observe.
    private(set) var frame = 0
    /// Set for one step after eating, so the head can flash without the view
    /// needing a timer of its own.
    private(set) var justAte = false

    @ObservationIgnored private var occupied: Set<SnakeCell> = []
    @ObservationIgnored private var heading: SnakeDirection = .right
    /// Turns are queued rather than applied immediately. At 150ms a step, two
    /// quick presses — right then down, rounding a corner — would otherwise
    /// have the first overwritten by the second and the corner missed.
    @ObservationIgnored private var pending: [SnakeDirection] = []
    @ObservationIgnored private var loop: Task<Void, Never>?

    init() {
        best = UserDefaults.standard.integer(forKey: Self.highScoreDefaultsKey)
        reset()
    }

    // MARK: Lifecycle

    /// Whether the loop is stepping. Exposed so the panel can drive it from one
    /// place and a test can assert it stopped.
    var isRunning: Bool { loop != nil }

    /// The single funnel for "is the board actually on screen", driven from
    /// `NotchPromptView.sync()` on the leading edge of every change.
    ///
    /// The leading edge is the whole point. `onDisappear` cannot do this job:
    /// closing the notch schedules an 800ms `clearTask` before the view is
    /// unmounted, so the loop kept stepping 5–11 more times off screen — long
    /// enough for `esc` to walk the snake into a wall and write a worse high
    /// score than the player actually earned.
    func setRunning(_ running: Bool) {
        if running { start() } else { stop() }
    }

    /// Idempotent, because the view's `onAppear` can fire more than once for a
    /// surface that is shown, hidden and shown again.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = self.interval
                try? await Task.sleep(for: .milliseconds(wait))
                guard !Task.isCancelled else { return }
                self.step()
            }
        }
    }

    /// Synchronous in the way that matters: `loop` is cleared before this
    /// returns, so nothing can observe a stopped game that still says it is
    /// running. The cancelled task may still be unwinding, but it re-checks
    /// `Task.isCancelled` after its sleep and so cannot land another `step()`.
    func stop() {
        loop?.cancel()
        loop = nil
    }

    deinit { loop?.cancel() }

    // MARK: Controls

    func turn(_ direction: SnakeDirection) {
        switch phase {
        case .ready:
            // The first turn is also the start, so there is no separate "press
            // space to begin" for anyone who just starts steering.
            phase = .playing
            if !direction.reverses(heading) { heading = direction }
        case .playing:
            guard pending.count < 2 else { return }
            let last = pending.last ?? heading
            guard !direction.reverses(last), direction != last else { return }
            pending.append(direction)
        case .over:
            break
        }
    }

    /// Space and return: start, or play again.
    func confirm() {
        switch phase {
        case .ready: phase = .playing
        case .playing: break
        case .over: reset()
        }
    }

    func reset() {
        let midY = Self.rows / 2
        body = [
            SnakeCell(x: 4, y: midY),
            SnakeCell(x: 3, y: midY),
            SnakeCell(x: 2, y: midY),
        ]
        occupied = Set(body)
        heading = .right
        pending.removeAll()
        score = 0
        justAte = false
        phase = .ready
        placeFood()
        frame &+= 1
    }

    // MARK: The step

    /// Speeds up with the score, then stops. An endlessly accelerating snake
    /// stops being a game about planning and becomes one about reflexes, which
    /// is not what this surface is for.
    private var interval: Int {
        max(Self.fastestInterval, Self.openingInterval - score * 4)
    }

    private func step() {
        frame &+= 1
        guard phase == .playing else { return }

        if !pending.isEmpty {
            let next = pending.removeFirst()
            if !next.reverses(heading) { heading = next }
        }

        let delta = heading.step
        let head = SnakeCell(x: body[0].x + delta.x, y: body[0].y + delta.y)

        guard head.x >= 0, head.x < Self.columns, head.y >= 0, head.y < Self.rows else {
            finish()
            return
        }

        // Vacate the tail *before* testing the head, so following your own tail
        // round a corner is legal — the cell it is leaving this very step is not
        // a cell you can collide with.
        let eating = head == food
        if !eating, let tail = body.last {
            body.removeLast()
            occupied.remove(tail)
        }

        guard !occupied.contains(head) else {
            finish()
            return
        }

        body.insert(head, at: 0)
        occupied.insert(head)
        justAte = eating

        if eating {
            score += 1
            placeFood()
        }
    }

    private func finish() {
        phase = .over
        justAte = false
        if score > best {
            best = score
            UserDefaults.standard.set(best, forKey: Self.highScoreDefaultsKey)
        }
    }

    /// Chosen from the free cells rather than by rejection sampling. Guessing
    /// at random is fine on an empty board and unbounded on a nearly full one,
    /// and a 260-cell board is small enough that listing the gaps is cheaper
    /// than the first few rejected guesses would be.
    private func placeFood() {
        var free: [SnakeCell] = []
        free.reserveCapacity(Self.columns * Self.rows - occupied.count)
        for y in 0..<Self.rows {
            for x in 0..<Self.columns {
                let cell = SnakeCell(x: x, y: y)
                if !occupied.contains(cell) { free.append(cell) }
            }
        }
        guard let spot = free.randomElement() else {
            // Nowhere left to put one: the board is full, which is a win.
            finish()
            return
        }
        food = spot
    }
}
