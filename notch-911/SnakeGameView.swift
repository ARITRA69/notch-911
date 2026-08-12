//
//  SnakeGameView.swift
//  notch-911
//
//  Snake, drawn.
//
//  A grid game is pixel art by construction: every cell is a whole number of
//  points on a lattice that starts at the origin, so nothing lands on a half
//  pixel and there is no framebuffer-and-blit indirection needed to keep the
//  edges hard. Each cell is drawn as a square inset by two points, which is
//  what puts the dark seam between segments and makes the body read as a run of
//  blocks rather than a rounded tube.
//
//  The canvas redraws when the game ticks — eight to fourteen times a second —
//  because that is the only time anything on the board changes.
//

import SwiftUI

// MARK: - Palette

private extension Color {
    /// 0xRRGGBB. Local to this file so it can't collide with anything else.
    init(snake hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private enum Board {
    static let backdrop = Color(snake: 0x0E1520)
    static let grid = Color(snake: 0x18212F)
    static let wall = Color(snake: 0x263349)

    static let body = Color(snake: 0x35B93C)
    static let bodyLit = Color(snake: 0x59DC55)
    static let head = Color(snake: 0x7BED5F)
    static let eye = Color(snake: 0x0E1520)

    static let apple = Color(snake: 0xE8433A)
    static let appleLit = Color(snake: 0xFF7D63)
    static let stem = Color(snake: 0x35B93C)

    static let panel = Color(snake: 0xF7F3E2)
    static let ink = Color(snake: 0x16202E)
}

// MARK: - Surface

/// The game as it sits in the notch: the board, the score, a way back to the
/// peek, and `esc` to leave — the same frame the clipboard surface wears.
struct SnakeSurface: View {
    let coordinator: PromptCoordinator
    let game: SnakeGame

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            SnakeGameView(game: game)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            footer
        }
        .background(escape)
    }

    private var heading: some View {
        HStack(spacing: 4) {
            Button { coordinator.backToPeek() } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the notch overview")
            Image(systemName: "square.grid.3x3.fill")
            Text("Snake")
            Spacer(minLength: 0)
            Text("\(game.score)")
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
            Text("best \(game.best)")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.35))
    }

    private var footer: some View {
        Text("arrows or WASD to steer · space to restart · ⎋ close")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.25))
    }

    /// `esc` can't go through `onKeyPress` with the rest: the canvas only has
    /// focus while it is the first responder, and leaving the surface has to
    /// work even when a pointer control took focus away from it.
    private var escape: some View {
        Button("") { coordinator.closeGame() }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

// MARK: - Board

struct SnakeGameView: View {

    let game: SnakeGame

    @FocusState private var focused: Bool

    /// 24pt cells. Big enough that a segment reads as a deliberate block rather
    /// than a smudge, and a whole number so every edge lands on a point
    /// boundary.
    static let cell: CGFloat = 24
    static var displaySize: CGSize {
        CGSize(
            width: CGFloat(SnakeGame.columns) * cell,
            height: CGFloat(SnakeGame.rows) * cell
        )
    }

    var body: some View {
        // Read the observable state here rather than inside the canvas closure:
        // the closure runs in the draw pass, and only what `body` touches is
        // registered as a dependency worth redrawing for.
        let segments = game.body
        let food = game.food
        let phase = game.phase
        let score = game.score
        let best = game.best
        let ate = game.justAte
        // Read but unused: the step counter is what guarantees a redraw on every
        // tick, including the ones where the board happens to look the same.
        let _ = game.frame

        Canvas { context, size in
            draw(in: context, size: size, segments: segments, food: food, ate: ate)
            drawOverlay(in: context, size: size, phase: phase, score: score, best: best)
        }
        .frame(width: Self.displaySize.width, height: Self.displaySize.height)
        .background(Board.backdrop)
        .overlay(alignment: .bottomTrailing) { pad }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            game.start()
            focused = true
        }
        .onDisappear { game.stop() }
        .onKeyPress(keys: [.upArrow, "w"], phases: .down) { _ in game.turn(.up); return .handled }
        .onKeyPress(keys: [.downArrow, "s"], phases: .down) { _ in game.turn(.down); return .handled }
        .onKeyPress(keys: [.leftArrow, "a"], phases: .down) { _ in game.turn(.left); return .handled }
        .onKeyPress(keys: [.rightArrow, "d"], phases: .down) { _ in game.turn(.right); return .handled }
        .onKeyPress(keys: [.space, .return], phases: .down) { _ in game.confirm(); return .handled }
        .contentShape(Rectangle())
    }

    // MARK: Pointer controls
    //
    // The notch cannot always be relied on to hold the keyboard — a peek never
    // takes it at all — so every direction has a pointer equivalent.

    private var pad: some View {
        VStack(spacing: 2) {
            arrow("chevron.up", .up)
            HStack(spacing: 2) {
                arrow("chevron.left", .left)
                arrow("chevron.down", .down)
                arrow("chevron.right", .right)
            }
        }
        .padding(6)
    }

    private func arrow(_ symbol: String, _ direction: SnakeDirection) -> some View {
        Button { game.turn(direction) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 24, height: 18)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Steer \(symbol)")
    }

    // MARK: Drawing

    private func rect(_ cell: SnakeCell, inset: CGFloat = 0) -> CGRect {
        CGRect(
            x: CGFloat(cell.x) * Self.cell + inset,
            y: CGFloat(cell.y) * Self.cell + inset,
            width: Self.cell - inset * 2,
            height: Self.cell - inset * 2
        )
    }

    private func draw(
        in context: GraphicsContext,
        size: CGSize,
        segments: [SnakeCell],
        food: SnakeCell,
        ate: Bool
    ) {
        // The lattice, one point wide. Faint enough to be a texture rather than
        // a grid you count squares on.
        var lines = Path()
        for column in 1..<SnakeGame.columns {
            let x = CGFloat(column) * Self.cell
            lines.move(to: CGPoint(x: x, y: 0))
            lines.addLine(to: CGPoint(x: x, y: size.height))
        }
        for row in 1..<SnakeGame.rows {
            let y = CGFloat(row) * Self.cell
            lines.move(to: CGPoint(x: 0, y: y))
            lines.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(lines, with: .color(Board.grid), lineWidth: 1)
        context.stroke(
            Path(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)),
            with: .color(Board.wall),
            lineWidth: 2
        )

        drawApple(in: context, at: food)

        for (index, segment) in segments.enumerated().reversed() {
            let isHead = index == 0
            context.fill(
                Path(rect(segment, inset: 2)),
                with: .color(isHead ? Board.head : Board.body)
            )
            // A lighter square in the top-left of each block: the cheapest
            // shading that still reads as a light source rather than a bevel.
            context.fill(
                Path(rect(segment, inset: 2).insetBy(dx: 4, dy: 4).offsetBy(dx: -2, dy: -2)),
                with: .color(isHead ? Board.head : Board.bodyLit)
            )
        }

        if let head = segments.first {
            drawEyes(in: context, head: head, next: segments.dropFirst().first, wide: ate)
        }
    }

    private func drawApple(in context: GraphicsContext, at cell: SnakeCell) {
        let box = rect(cell, inset: 4)
        context.fill(Path(box), with: .color(Board.apple))
        context.fill(
            Path(CGRect(x: box.minX + 2, y: box.minY + 2, width: 4, height: 4)),
            with: .color(Board.appleLit)
        )
        context.fill(
            Path(CGRect(x: box.midX - 1.5, y: box.minY - 4, width: 3, height: 4)),
            with: .color(Board.stem)
        )
    }

    /// Eyes face the way the snake is going, worked out from the two leading
    /// cells rather than from the game's heading — the view has no business
    /// knowing about a queued turn that hasn't been taken yet.
    private func drawEyes(
        in context: GraphicsContext,
        head: SnakeCell,
        next: SnakeCell?,
        wide: Bool
    ) {
        let dx = next.map { head.x - $0.x } ?? 1
        let dy = next.map { head.y - $0.y } ?? 0
        let box = rect(head, inset: 2)
        let size: CGFloat = wide ? 6 : 4
        let along: CGFloat = 5
        let apart: CGFloat = 5

        let centre = CGPoint(x: box.midX + CGFloat(dx) * along, y: box.midY + CGFloat(dy) * along)
        // Offset the pair perpendicular to travel.
        let offset = CGPoint(x: CGFloat(dy) * apart, y: CGFloat(dx) * apart)

        for sign in [-1.0, 1.0] {
            let eye = CGRect(
                x: centre.x + offset.x * sign - size / 2,
                y: centre.y + offset.y * sign - size / 2,
                width: size, height: size
            )
            context.fill(Path(eye), with: .color(Board.eye))
        }
    }

    private func drawOverlay(
        in context: GraphicsContext,
        size: CGSize,
        phase: SnakeGame.Phase,
        score: Int,
        best: Int
    ) {
        let copy: (String, String)? = switch phase {
        case .ready: ("SNAKE", "arrows or WASD to start")
        case .over: ("GAME OVER", score >= best && score > 0
            ? "new best · \(score) · space to play again"
            : "\(score) · best \(best) · space to play again")
        case .playing: nil
        }
        guard let (title, hint) = copy else { return }

        let card = CGRect(x: size.width / 2 - 130, y: size.height / 2 - 40, width: 260, height: 80)
        context.fill(Path(card.offsetBy(dx: 3, dy: 4)), with: .color(.black.opacity(0.35)))
        context.fill(Path(card), with: .color(Board.ink))
        context.fill(Path(card.insetBy(dx: 3, dy: 3)), with: .color(Board.panel))

        context.draw(
            Text(title).font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(Board.ink),
            at: CGPoint(x: card.midX, y: card.midY - 12)
        )
        context.draw(
            Text(hint).font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Board.ink.opacity(0.7)),
            at: CGPoint(x: card.midX, y: card.midY + 18)
        )
    }
}
