//
//  NotchPanel.swift
//  notch-911
//
//  The notch surface. Window strategy per §6.2: one fixed-size transparent panel
//  created at launch, floating above fullscreen apps, taking keystrokes without
//  stealing focus. The window is never moved or resized after creation — AppKit
//  frame animation isn't synchronised to the SwiftUI render loop and tears at
//  120Hz. Only the SwiftUI content animates.
//

import AppKit
import SwiftUI

// MARK: - Window

final class NotchPanel: NSPanel {
    /// Without this the panel can never take keyboard input. Combined with
    /// `.nonactivatingPanel` it takes keys *without* activating the app.
    ///
    /// Flipped per surface by the controller rather than left permanently on.
    /// `setVisible(false)` defers `orderOut` by 800ms so the collapse spring can
    /// finish, and a panel that stays key for those 800ms eats whatever the user
    /// types straight after their own `esc` — which, for a surface summoned by a
    /// global hotkey, is exactly when they are mid-sentence. A keypress that
    /// silently disappears is worse than one that beeps.
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// A sliver of window living permanently over the notch, whose only job is to
/// notice the pointer. Kept separate from the content panel so the content panel
/// can still be ordered out when idle: a window that must stay on screen to
/// detect hover would otherwise have to swallow clicks or fake its own
/// hit-testing across the whole 720×620 frame.
final class HoverSensorPanel: NSPanel {
    /// Never key — it must never take a keystroke away from the user's app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Where the notch is, and what to do when there isn't one (§6.1).
enum NotchGeometry {
    static func screen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    static var inset: CGFloat {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }?.safeAreaInsets.top ?? 0
    }

    static var hasNotch: Bool { inset > 0 }

    /// How far down content must start to clear the camera housing — or, on a
    /// Mac without one, the menu bar.
    static var topInset: CGFloat {
        hasNotch ? inset : NSStatusBar.system.thickness
    }

    /// Width of the physical notch, derived from the auxiliary menu bar areas
    /// either side of it. Never hardcoded (§6.1).
    static func notchWidth(on screen: NSScreen) -> CGFloat {
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        guard left > 0, right > 0 else { return 200 }
        return max(120, screen.frame.width - left - right)
    }

    /// The strip the pointer has to rest on. On a notched Mac this is exactly
    /// the notch, where there is nothing else to click. Without a notch it is a
    /// deliberately shallow band at the top centre, to overlap as little of the
    /// menu bar as possible.
    ///
    /// With the mini player showing, the collapsed surface is wider (a wing per
    /// side for the disc) and a point taller — the sensor has to cover all of
    /// it, or hovering the cover art does nothing.
    static func sensorFrame(forMiniPlayer miniPlayer: Bool = false) -> CGRect? {
        guard let screen = screen() else { return nil }
        let frame = screen.frame
        var width = hasNotch ? notchWidth(on: screen) : 200
        var height = hasNotch ? inset : 8
        if miniPlayer {
            width += NotchPromptView.miniWing * 2
            height += NotchPromptView.miniExtraHeight
        }
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }
}

@MainActor
final class NotchPanelController: NSObject {

    /// Fixed at the maximum expanded bounds. Sized for the tallest surface we
    /// can present — a multi-field elicitation form — not the smallest. Not
    /// private: the shadow layer has to know the ceiling it draws into.
    static let panelSize = CGSize(width: 720, height: 620)

    private let panel: NotchPanel
    private let sensor: HoverSensorPanel
    /// A sacrificial key window — see `evictKey()`.
    private let keySink: NotchPanel
    private let coordinator: PromptCoordinator
    private let media: MediaMonitor

    init(
        coordinator: PromptCoordinator,
        media: MediaMonitor,
        shelf: ShelfStore,
        clipboard: ClipboardStore
    ) {
        self.coordinator = coordinator
        self.media = media

        sensor = HoverSensorPanel(
            contentRect: NotchGeometry.sensorFrame() ?? .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        sensor.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        sensor.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sensor.isOpaque = false
        sensor.backgroundColor = .clear
        sensor.hasShadow = false
        sensor.isMovable = false
        sensor.hidesOnDeactivate = false
        sensor.isReleasedWhenClosed = false
        sensor.contentView = NSHostingView(
            rootView: HoverSensorView(
                shelf: shelf,
                onHover: { coordinator.hoverChanged($0) },
                onDragTargeting: { coordinator.dragOverSensor($0) }
            )
        )

        panel = NotchPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces,      // follows the user across desktops
            .fullScreenAuxiliary,   // this is what puts it over fullscreen apps
            .stationary,
            .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false     // drawn in SwiftUI; see §6.4
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(
            rootView: NotchPromptView(
                coordinator: coordinator,
                media: media,
                shelf: shelf,
                clipboard: clipboard
            )
        )
        hosting.frame = CGRect(origin: .zero, size: Self.panelSize)
        panel.contentView = hosting

        // Invisible on purpose: one point, fully transparent, at the panel's
        // own level so ordering it front never rearranges anything the user
        // can see. Its entire job is to be a window that key status can pass
        // through on its way back to the user's app — see `evictKey`.
        keySink = NotchPanel(
            contentRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        keySink.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        keySink.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        keySink.isOpaque = false
        keySink.backgroundColor = .clear
        keySink.hasShadow = false
        keySink.alphaValue = 0
        keySink.isMovable = false
        keySink.hidesOnDeactivate = false
        keySink.isReleasedWhenClosed = false
        keySink.acceptsKeyboard = true

        super.init()
        panel.delegate = self

        reposition()
        sensor.orderFrontRegardless()
    }

    /// Takes key status away from the panel without taking the panel off the
    /// screen. `orderOut` is the only supported way to make a window resign
    /// key, but macOS animates window ordering — ordering the panel out and
    /// straight back re-renders the whole surface with a system fade-out and
    /// fade-in, which on a surface swap reads as the panel blinking away and
    /// popping back. So the eviction is done with a sacrifice instead: an
    /// invisible one-point panel briefly becomes key (nonactivating, so the
    /// app never activates) and is immediately ordered out. The system
    /// animates a window nobody can see, and key status settles back on the
    /// user's own app — the visible panel never moves.
    private func evictKey() {
        guard panel.isKeyWindow else { return }
        keySink.makeKeyAndOrderFront(nil)
        keySink.orderOut(nil)
    }

    private var hideTask: Task<Void, Never>?

    func setVisible(_ visible: Bool) {
        hideTask?.cancel()
        // Visibility changes on every media transition too, so this is the one
        // spot that reliably sees the mini player come and go — resize the
        // sensor with it, or the wings aren't hoverable.
        repositionSensor()
        guard visible else {
            // The collapse runs on for most of a second but the keyboard has
            // to go back *now* — a panel that stays key eats whatever the
            // user types straight after their own `esc`. Evicted via the key
            // sink so the panel itself never leaves the screen mid-collapse.
            panel.acceptsKeyboard = false
            evictKey()
            // Ordering the window out immediately would kill the collapse
            // mid-flight. Let the spring finish shrinking the surface back into
            // the notch first, then remove the window.
            hideTask = Task { [panel] in
                // The collapse spring's 0.05 hold + its 0.42 response, with
                // slack for the settle tail — cutting the window mid-tail
                // clips the last few pixels of travel.
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                panel.orderOut(nil)
            }
            return
        }
        reposition()
        // The panel now stays on screen for the collapsed mini player, so it has
        // to stop swallowing clicks across its whole 720×620 frame when there is
        // nothing interactive in it.
        panel.ignoresMouseEvents = !coordinator.isInteractive
        panel.acceptsKeyboard = coordinator.wantsKeyboard
        if coordinator.wantsKeyboard {
            // A prompt or the clipboard. Both are surfaces the user asked for
            // and will type or arrow around in, so taking the keyboard is the
            // contract. A peek still must not: it opens on hover alone, and
            // swallowing the next thing the user typed into their editor is the
            // one unforgivable thing a hover surface can do.
            panel.makeKeyAndOrderFront(nil)
        } else {
            // `canBecomeKey` going false does *not* evict a window that is
            // already key. This branch is reachable on a clipboard→peek swap
            // and while the panel stays on screen for the collapsed mini
            // player, so closing the clipboard with music playing would
            // otherwise leave the panel holding the keyboard indefinitely,
            // swallowing every key the user pressed next — including the ⌘V
            // they opened it to press. Evicted via the key sink: ordering the
            // panel itself out and back showed up as the whole surface
            // blinking away in the middle of the swap animation.
            evictKey()
            panel.orderFrontRegardless()
        }
    }

    /// Anchors the panel to the top centre of the display that has the notch,
    /// falling back to the main display when there isn't one (§6.1).
    private func reposition() {
        guard let screen = NotchGeometry.screen() else { return }
        let frame = screen.frame
        panel.setFrameOrigin(
            CGPoint(
                x: frame.midX - Self.panelSize.width / 2,
                y: frame.maxY - Self.panelSize.height
            )
        )
        repositionSensor()
    }

    private func repositionSensor() {
        if let sensorFrame = NotchGeometry.sensorFrame(forMiniPlayer: media.nowPlaying != nil) {
            sensor.setFrame(sensorFrame, display: false)
        }
    }
}

extension NotchPanelController: NSWindowDelegate {
    /// The panel loses key when the user clicks into another app. For the
    /// clipboard that means "never mind", the same as `esc` — a picker you
    /// summoned and then ignored should not stay on screen.
    ///
    /// Strictly guarded on `.clipboard`: a prompt is a blocked session, and the
    /// user going somewhere else to think about it is the most ordinary thing in
    /// the world.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            switch coordinator.idleSurface {
            case .clipboard: coordinator.closeClipboard()
            // Same reasoning, and no loss: the game object outlives the
            // surface, so reopening resumes the stage mid-roll.
            case .game: coordinator.closeGame()
            case .peek, .none: break
            }
        }
    }
}

/// Transparent, but hit-testable — `Color.clear` alone receives no hover events.
private struct HoverSensorView: View {
    let shelf: ShelfStore
    let onHover: (Bool) -> Void
    let onDragTargeting: (Bool) -> Void

    var body: some View {
        Color.white.opacity(0.001)
            .contentShape(Rectangle())
            .onHover(perform: onHover)
            // Dropping straight onto the notch shelves the file, so you never
            // have to wait for the panel before letting go.
            .dropDestination(for: URL.self) { urls, _ in
                shelf.accept(urls)
            } isTargeted: {
                onDragTargeting($0)
            }
    }
}

// MARK: - Shape

/// The panel silhouette: flush with the top of the display, flaring *outward*
/// into the menu bar with concave corners before dropping into a convex-bottomed
/// slab. That concave top corner is what makes the surface read as the notch
/// growing rather than a window parked underneath it (§6.3).
///
/// M0 approximates the flares with quadratic curves. M1 replaces them with true
/// continuous-curvature arcs screenshot-diffed against the real notch.
struct NotchShape: Shape {
    var topFlareRadius: CGFloat = 12
    var bottomCornerRadius: CGFloat = 22

    /// Makes the radii interpolate rather than jump, so the collapse is one
    /// continuous element morphing back into the notch (§7.1) instead of a
    /// crossfade between two shapes.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFlareRadius, bottomCornerRadius) }
        set {
            topFlareRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Clamped: mid-collapse the surface is only as tall as the notch, and an
        // unclamped radius would fold the path back through itself.
        let flare = max(0, min(topFlareRadius, rect.width / 2))
        let corner = max(0, min(bottomCornerRadius, rect.height / 2, (rect.width - flare * 2) / 2))
        let left = rect.minX + flare
        let right = rect.maxX - flare

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.minY + flare),
            control: CGPoint(x: left, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: left, y: rect.maxY - corner))
        path.addQuadCurve(
            to: CGPoint(x: left + corner, y: rect.maxY),
            control: CGPoint(x: left, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right - corner, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.maxY - corner),
            control: CGPoint(x: right, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: right, y: rect.minY + flare))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: right, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

/// Reports the laid-out height of the card so the shadow can scale with it.
private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Container

/// Owns the one continuous surface. §7.1 asks for the collapsed notch shape and
/// the expanded panel to interpolate as a single element — so rather than
/// inserting and removing a card with a transition, one shape lives here
/// permanently and its bounds and corner radii animate between notch-sized and
/// content-sized. The content merely fades on top of it.
struct NotchPromptView: View {
    let coordinator: PromptCoordinator
    let media: MediaMonitor
    let shelf: ShelfStore
    let clipboard: ClipboardStore

    /// What the surface is rendering. Held in view state rather than read
    /// straight from the coordinator so the content outlives the collapse:
    /// clearing it the moment the user answers would empty the surface and make
    /// it snap shut instead of shrinking back into the notch.
    @State private var shownPrompt: Prompt?
    /// Which idle surface is being rendered. One value rather than a flag each:
    /// at three surfaces, independent flags start admitting combinations that
    /// cannot exist.
    @State private var shownIdle: IdleSurface = .none
    /// Created the first time the game is opened, and kept afterwards so
    /// closing the notch mid-run is a pause rather than a loss. Nothing about
    /// it is built for anyone who never opens it.
    @State private var snake: SnakeGame?
    @State private var contentHeight: CGFloat = 0
    @State private var clearTask: Task<Void, Never>?
    @State private var expandTask: Task<Void, Never>?
    /// Drives the surface. Deliberately separate from "the coordinator wants to
    /// be open": the content is mounted (invisible) one layout pass earlier, so
    /// that by the time this flips the surface already knows its target height
    /// and springs straight to it instead of correcting mid-flight.
    @State private var isExpanded = false

    private static let flare: CGFloat = 12
    private static let promptWidth: CGFloat = 520
    // Three columns: 56pt cover + centre + the shelf's fixed 136pt.
    private static let peekWidth: CGFloat = 540
    /// Wide enough for a two-line text snippet beside a 32pt thumbnail and a
    /// trailing meta column without either truncating at a glance. 640 plus the
    /// flares is 664, which the fixed 720pt panel still clears (§6.2 — the
    /// window is never resized, so this is a hard ceiling, not a suggestion).
    private static let clipboardWidth: CGFloat = 640
    /// Whatever the board needs, plus the card's own horizontal padding.
    /// Derived rather than typed out: the grid cannot be squeezed to fit a
    /// number chosen here without cells landing on fractional points.
    private static let gameWidth: CGFloat =
        SnakeGameView.displaySize.width + 32
    /// Roughly the physical notch's own bottom corner radius.
    private static let notchBottomRadius: CGFloat = 10
    private static let openBottomRadius: CGFloat = 22
    private static let discSize: CGFloat = 22
    private static let discPadding: CGFloat = 6
    /// Wing width either side of the notch when collapsed with music. Not
    /// private: `NotchGeometry.sensorFrame` needs it to make the wings hoverable.
    ///
    /// `NotchShape` insets its body by `flare` on each side — only the very top
    /// edge spans the full rect, the sides curve inward below it. So the wing
    /// has to pay for the flare *on top of* the disc and its padding, or the
    /// disc sits on the curve and hangs off the edge of the surface.
    static let miniWing: CGFloat = flare + discSize + discPadding * 2
    /// The collapsed surface sits this much proud of the physical notch while
    /// the mini player is showing, so the black slab reads as its own shape
    /// rather than vanishing exactly into the bezel.
    static let miniExtraHeight: CGFloat = 1


    private var openWidth: CGFloat {
        let content: CGFloat
        if shownPrompt != nil { content = Self.promptWidth }
        else if shownIdle == .clipboard { content = Self.clipboardWidth }
        else if shownIdle == .game { content = Self.gameWidth }
        else { content = Self.peekWidth }
        return content + Self.flare * 2
    }

    /// The physical notch, with nothing added.
    private var bareNotchWidth: CGFloat {
        NotchGeometry.screen().map { NotchGeometry.notchWidth(on: $0) } ?? 200
    }

    private var hasMiniPlayer: Bool { media.nowPlaying != nil }

    /// The copy acknowledgement, in the right wing. Mirrors the mini player.
    private var hasCopiedBadge: Bool { clipboard.justCaptured }

    /// Either wing's occupant is enough to open both — see `collapsedWidth`.
    private var hasWings: Bool { hasMiniPlayer || hasCopiedBadge }

    /// Collapsed, the surface grows a wing on each side to make room for the
    /// disc. Symmetric on purpose — growing only leftward would slide the
    /// physical notch off-centre inside the shape, which reads as misalignment
    /// rather than as the notch widening. That is why a copy badge, which only
    /// ever occupies the right wing, still opens both.
    private var collapsedWidth: CGFloat {
        bareNotchWidth + (hasWings ? Self.miniWing * 2 : 0)
    }

    private var collapsedHeight: CGFloat {
        max(NotchGeometry.topInset, 1) + (hasWings ? Self.miniExtraHeight : 0)
    }

    private var openHeight: CGFloat { max(contentHeight, collapsedHeight) }

    private var surfaceWidth: CGFloat { isExpanded ? openWidth : collapsedWidth }
    private var surfaceHeight: CGFloat { isExpanded ? openHeight : collapsedHeight }

    /// §7.1: expand overshoots slightly — it's the signature moment. Collapse
    /// keeps the same response so closing reads as the same element travelling
    /// back, not a hard cut: at 0.32s with a 0.10s hold, most of the visible
    /// area change landed inside 150ms and `esc` felt like the panel simply
    /// vanishing. Flatter damping than the open because an overshoot on exit
    /// looks like a bounce off the bezel; the short hold gives the content
    /// fade a head start without reading as a hiccup.
    private var containerSpring: Animation {
        isExpanded
            ? .spring(response: 0.42, dampingFraction: 0.78)
            : .spring(response: 0.42, dampingFraction: 0.86).delay(0.05)
    }

    /// Content arrives only once the container has *finished* growing. §7.1's
    /// 0.08s delay was written against a container that had already committed to
    /// its size; with a 0.42s spring the shape is barely a fifth of the way
    /// there at 0.08s, so the content used to swim into place while the panel
    /// was still opening. 0.30s puts it after the spring has settled.
    private var contentFade: Animation {
        isExpanded ? .easeOut(duration: 0.2).delay(0.30) : .easeIn(duration: 0.12)
    }

    /// Collapsed, the shape sits exactly over the physical notch and is
    /// invisible against it. Without a notch there is nothing to hide behind, so
    /// it fades out instead of parking a black bar on the menu bar — except
    /// while the copy badge is up, which needs something to sit on.
    private var surfaceOpacity: Double {
        isExpanded || NotchGeometry.hasNotch || hasCopiedBadge ? 1 : 0
    }

    var body: some View {
        ZStack(alignment: .top) {
            shadowLayer
            surface
            miniPlayer
            copiedBadge
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: coordinator.current?.id) { _, _ in sync() }
        .onChange(of: coordinator.idleSurface) { _, _ in sync() }
        .onAppear { sync() }
    }

    /// §7.2 to the letter: a static layer behind the panel that fades but does
    /// not resize. Fixing it at the open bounds means the blur is rasterised
    /// once per prompt instead of once per frame of the spring — the animating
    /// surface above carries no shadow of its own.
    private var shadowLayer: some View {
        NotchShape(
            topFlareRadius: Self.flare,
            bottomCornerRadius: Self.openBottomRadius
        )
        .fill(Color.black)
        .frame(width: openWidth, height: openHeight)
        .compositingGroup()
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowOffsetY)
        .opacity(isExpanded ? 1 : 0)
        .animation(contentFade, value: isExpanded)
        .allowsHitTesting(false)
    }

    private var surface: some View {
        NotchShape(
            topFlareRadius: Self.flare,
            bottomCornerRadius: isExpanded ? Self.openBottomRadius : Self.notchBottomRadius
        )
        .fill(Color.black)
        .overlay(
            NotchShape(
                topFlareRadius: Self.flare,
                bottomCornerRadius: isExpanded ? Self.openBottomRadius : Self.notchBottomRadius
            )
            .stroke(.white.opacity(isExpanded ? 0.08 : 0), lineWidth: 0.5)
        )
        .frame(width: surfaceWidth, height: surfaceHeight)
        .opacity(surfaceOpacity)
        .animation(containerSpring, value: surfaceWidth)
        .animation(containerSpring, value: surfaceHeight)
        .animation(containerSpring, value: isExpanded)
        .allowsHitTesting(false)
    }

    /// The collapsed state when music is playing: a small spinning disc in the
    /// left wing. Always mounted and driven by opacity rather than inserted and
    /// removed, so it cross-fades with the expanded content instead of popping.
    private var miniPlayer: some View {
        let visible = hasMiniPlayer && !isExpanded
        return SpinningDisc(
            image: media.artwork,
            // Stops the rotation loop whenever the disc isn't actually on
            // screen, so expanding the peek doesn't leave it spinning unseen.
            isSpinning: visible && (media.nowPlaying?.isPlaying ?? false),
            size: Self.discSize
        )
        // Centred in the usable part of the left wing: everything between the
        // notch's left edge and where the shape's body actually ends, which is
        // `flare` short of the rect.
        .offset(
            x: -(bareNotchWidth / 2 + (Self.miniWing - Self.flare) / 2),
            y: (collapsedHeight - Self.discSize) / 2
        )
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.6)
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: hasMiniPlayer)
        .animation(contentFade, value: isExpanded)
        .allowsHitTesting(false)
    }

    /// The copy acknowledgement: a checkmark in the right wing, opposite the
    /// mini player's disc. Always mounted and driven by opacity and scale rather
    /// than inserted and removed, exactly like `miniPlayer` — a transition would
    /// fight the wing that is growing underneath it.
    ///
    /// The timing is deliberately staggered against the wing. `containerSpring`
    /// carries a 0.10s hold while collapsed, so an undelayed badge would pop out
    /// before the shape had made room for it and hang over the bezel for a
    /// frame. Arriving 0.12s late lets the wing lead; leaving on a plain ease-in
    /// lets the badge go *first* and the wing close behind it, which is the same
    /// choreography `contentFade` uses for the expanded surface.
    private var copiedBadge: some View {
        let visible = hasCopiedBadge && !isExpanded
        return Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: Self.discSize, height: Self.discSize)
            .background(Circle().fill(.white.opacity(0.14)))
            // Mirror of the mini player's offset: centred in the usable part of
            // the right wing, which ends `flare` short of the rect.
            .offset(
                x: bareNotchWidth / 2 + (Self.miniWing - Self.flare) / 2,
                y: (collapsedHeight - Self.discSize) / 2
            )
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.5)
            .animation(badgeAnimation, value: hasCopiedBadge)
            .animation(contentFade, value: isExpanded)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var badgeAnimation: Animation {
        hasCopiedBadge
            ? .spring(response: 0.34, dampingFraction: 0.72).delay(0.12)
            : .easeIn(duration: 0.12)
    }

    private var content: some View {
        Group {
            if let prompt = shownPrompt {
                PromptCard(prompt: prompt, coordinator: coordinator)
                    // Fresh identity per prompt, so every field, selection and
                    // focus state resets when the queue advances rather than
                    // bleeding the last answer into the next question.
                    .id(prompt.id)
            } else if shownIdle == .game, let snake {
                SnakeSurface(coordinator: coordinator, game: snake)
            } else if shownIdle == .clipboard {
                ClipboardCard(store: clipboard, coordinator: coordinator)
            } else if shownIdle == .peek {
                PeekCard(
                    coordinator: coordinator,
                    media: media,
                    shelf: shelf,
                    clipboard: clipboard
                )
            }
        }
        .padding(.top, NotchGeometry.topInset + 8)   // clears the camera housing
        .padding(.horizontal, 16 + Self.flare)
        .padding(.bottom, 16)
        .frame(width: openWidth, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CardHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(CardHeightKey.self) { height in
            // Delivered during the main-actor view update.
            MainActor.assumeIsolated { contentHeight = height }
        }
        .opacity(isExpanded ? 1 : 0)
        .animation(contentFade, value: isExpanded)
        .allowsHitTesting(isExpanded)
        .contentShape(Rectangle())
        // Tracked here rather than inside PeekCard: a transport command
        // re-renders the card, and hover state attached to the card itself gets
        // dropped in the rebuild — so pressing play would collapse the panel.
        .onHover { hovering in
            guard shownIdle == .peek else { return }
            coordinator.peekHoverChanged(hovering)
        }
    }

    // MARK: Shadow, sized to content

    private static let baselineHeight: CGFloat = 150
    private var overhang: CGFloat { max(0, openHeight - Self.baselineHeight) }
    /// Never ask for more blur than the window can render. The panel is fixed at
    /// 720 and never resized (§6.2), so at the clipboard's 664pt surface there
    /// are only 28pt of margin per side — an unclamped 34pt radius draws a
    /// shadow with a hard vertical cut down both edges.
    private var shadowRadius: CGFloat {
        min(
            34,
            (NotchPanelController.panelSize.width - openWidth) / 2,
            12 + overhang * 0.10
        )
    }
    private var shadowOffsetY: CGFloat { min(16, 5 + overhang * 0.045) }
    private var shadowOpacity: Double { min(0.55, 0.30 + Double(overhang) * 0.0009) }

    // MARK: Content lifetime

    private func sync() {
        clearTask?.cancel()
        expandTask?.cancel()

        if let prompt = coordinator.current {
            shownPrompt = prompt
            setIdleContent(.none)
            expandOnceMeasured()
            return
        }

        switch coordinator.idleSurface {
        case .game:
            shownPrompt = nil
            // Built here rather than with the panel: nothing about the board
            // costs anything to someone who never opens the game.
            if snake == nil { snake = SnakeGame() }
            setIdleContent(.game)
            expandOnceMeasured()
        case .clipboard:
            shownPrompt = nil
            setIdleContent(.clipboard)
            expandOnceMeasured()
        case .peek:
            shownPrompt = nil
            setIdleContent(.peek)
            expandOnceMeasured()
        case .none:
            isExpanded = false
            // Outlive the content fade plus the delayed collapse spring, then
            // drop the content.
            clearTask = Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                shownPrompt = nil
                shownIdle = .none
            }
        }
    }

    /// Swapping between two *already open* surfaces is a cross-fade, not an
    /// expansion: the shape is out and stays out, only the content changes
    /// hands. `expandOnceMeasured` no-ops in that case (it guards `!isExpanded`),
    /// so without this the peek→clipboard swap from the chip would be an instant
    /// hard cut over a shape that is meanwhile springing 564→664.
    ///
    /// Deliberately *not* animated when collapsed: `contentFade` already owns
    /// that transition, and a second animation on the same change double-fades
    /// it.
    private func setIdleContent(_ surface: IdleSurface) {
        if isExpanded {
            withAnimation(.easeInOut(duration: 0.16)) { shownIdle = surface }
        } else {
            shownIdle = surface
        }
    }

    /// Mounts the content, waits one turn for it to lay out and report its
    /// height, then opens. Without the gap the spring starts against a stale
    /// `contentHeight` — usually zero on the very first prompt — and visibly
    /// re-targets partway through the expansion.
    private func expandOnceMeasured() {
        guard !isExpanded else { return }
        expandTask = Task {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            isExpanded = true
        }
    }
}

// MARK: - Peek

/// The idle surface. Strictly about agents: what is blocked, what is stranded,
/// and whether the connectors are live. Nothing here is useful when no agent is
/// running, which is the §2 test for whether a feature belongs in this app.
struct PeekCard: View {
    let coordinator: PromptCoordinator
    let media: MediaMonitor
    let shelf: ShelfStore
    let clipboard: ClipboardStore

    @State private var clipboardHovered = false
    @State private var gameHovered = false

    /// Left column is exactly the cover, so the transport underneath lines up
    /// with its edges.
    private static let coverSize: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 16) {
                if media.nowPlaying != nil {
                    playerColumn
                }
                agentColumn
                Spacer(minLength: 0)
                ShelfView(store: shelf) { targeted in
                    // A drag session suppresses hover events, so without this the
                    // peek would close the moment the pointer left the notch —
                    // taking the drop target with it.
                    coordinator.peekHoverChanged(targeted)
                }
            }
            connectors
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell.badge")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
            Text("notch-911")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
            Spacer()
            gameChip
            clipboardChip
            if !coordinator.stranded.isEmpty {
                Text("\(coordinator.stranded.count) waiting")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
            }
        }
    }

    /// The doorway into the clipboard surface, for anyone who hasn't learned
    /// ⇧⌘V — or whose ⇧⌘V is owned by another app. `RegisterEventHotKey`
    /// succeeds and then simply never fires when someone else already holds the
    /// chord, with no API to detect it, so there has to be a way in that can't
    /// silently break.
    ///
    /// A header chip rather than a fourth column beside `ShelfView`: the shelf
    /// earns its column by being a drop target that needs area, this is one
    /// button, and the peek has no width to spare — a 76pt column would take the
    /// centre from 284pt to 192pt and start truncating stranded prompts.
    /// Deliberately the same visual weight as the "n waiting" badge beside it.
    private var clipboardChip: some View {
        Button { coordinator.openClipboard() } label: {
            HStack(spacing: 4) {
                Image(systemName: clipboard.items.isEmpty
                      ? "doc.on.clipboard" : "doc.on.clipboard.fill")
                if !clipboard.items.isEmpty {
                    Text("\(clipboard.items.count)").monospacedDigit()
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white.opacity(clipboardHovered ? 0.75 : 0.45))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.white.opacity(clipboardHovered ? 0.14 : 0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { clipboardHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: clipboardHovered)
        .accessibilityLabel("Open clipboard history")
    }

    /// The way into Snake. Glyph only, and the quietest thing in the row: it is
    /// the one surface here nobody needs, and a peek that advertises a game
    /// louder than the prompts it exists to show would have its priorities
    /// backwards.
    private var gameChip: some View {
        Button { coordinator.openGame() } label: {
            Image(systemName: "square.grid.3x3.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(gameHovered ? 0.7 : 0.35))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.white.opacity(gameHovered ? 0.14 : 0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { gameHovered = $0 }
        .animation(.easeOut(duration: 0.14), value: gameHovered)
        .accessibilityLabel("Play Snake")
    }

    // MARK: Player column

    @ViewBuilder
    private var playerColumn: some View {
        if let track = media.nowPlaying {
            VStack(spacing: 8) {
                cover
                transport(track)
            }
            .frame(width: Self.coverSize)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    /// Album art, with a placeholder that holds the same footprint so the row
    /// doesn't reflow when the image lands a moment after the track data.
    private var cover: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.07))
            if let image = media.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(width: Self.coverSize, height: Self.coverSize)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.22), value: media.artwork != nil)
    }

    private func transport(_ track: MediaController.NowPlaying) -> some View {
        HStack(spacing: 0) {
            transportButton("backward.fill", label: "Previous track") { media.previous() }
            transportButton(
                track.isPlaying ? "pause.fill" : "play.fill",
                label: track.isPlaying ? "Pause" : "Play"
            ) { media.playPause() }
            transportButton("forward.fill", label: "Next track") { media.next() }
        }
        .frame(width: Self.coverSize)
    }

    private func transportButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .frame(height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Centre column

    private var agentColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            trackDetails
            agentState
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var trackDetails: some View {
        if let track = media.nowPlaying {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if let logo = track.source.logoAsset {
                        BrandMark(logo, size: 11)
                    } else {
                        Image(systemName: "music.note")
                    }
                    Text(track.source.displayName)
                    Spacer(minLength: 4)
                    Text(Self.timeLabel(track)).monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))

                Text(track.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)

                progressBar(track).padding(.top, 4)
            }
        } else if media.isPermissionDenied {
            hint("Allow notch-911 in System Settings → Privacy & Security → Automation to show what's playing.")
        } else if media.needsBrowserJavaScript {
            hint("YouTube Music is open. Turn on Develop → Allow JavaScript from Apple Events in that browser to read it.")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.35))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var agentState: some View {
        if coordinator.stranded.isEmpty {
            Text("Nothing blocked.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        } else {
            VStack(spacing: 4) {
                ForEach(coordinator.stranded.prefix(2)) { prompt in
                    strandedRow(prompt)
                }
            }
            if coordinator.stranded.count > 2 {
                Text("and \(coordinator.stranded.count - 2) more")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func progressBar(_ track: MediaController.NowPlaying) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(.white.opacity(0.5))
                    .frame(width: proxy.size.width * Self.fraction(track))
            }
        }
        .frame(height: 3)
        // Position only refreshes once a second; easing it stops the bar from
        // stepping.
        .animation(.linear(duration: 0.9), value: track.position)
    }

    private func strandedRow(_ prompt: Prompt) -> some View {
        Button {
            coordinator.resurface(prompt)
        } label: {
            HStack(spacing: 8) {
                // The tint only reaches OpenAI's template mark; the opacity is
                // what keeps Claude's coloured one at the same visual weight.
                BrandMark(prompt.agent.logoAsset, size: 11)
                    .foregroundStyle(.white.opacity(0.75))
                    .opacity(0.75)
                VStack(alignment: .leading, spacing: 1) {
                    Text(prompt.projectName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(prompt.title)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("Resume")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(prompt.projectName), \(prompt.title)")
    }

    private var connectors: some View {
        HStack(spacing: 12) {
            connector("Claude Code", on: coordinator.agentStatus.claudeConnected)
            connector("Codex", on: coordinator.agentStatus.codexConnected)
            Spacer()
            if let port = coordinator.agentStatus.port {
                Text(":\(String(port))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }

    private func connector(_ name: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on ? Color.green.opacity(0.8) : Color.white.opacity(0.2))
                .frame(width: 5, height: 5)
            Text(name)
                .font(.caption2)
                .foregroundStyle(.white.opacity(on ? 0.5 : 0.25))
        }
    }

    private static func fraction(_ track: MediaController.NowPlaying) -> Double {
        guard track.duration > 0 else { return 0 }
        return min(1, max(0, track.position / track.duration))
    }

    private static func timeLabel(_ track: MediaController.NowPlaying) -> String {
        "\(clock(track.position)) / \(clock(track.duration))"
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}


// MARK: - Card

struct PromptCard: View {
    let prompt: Prompt
    let coordinator: PromptCoordinator

    /// Selected wire values, per field. Single-selects hold at most one.
    @State private var selections: [UUID: Set<String>] = [:]
    /// Text and number field contents, per field.
    @State private var entries: [UUID: String] = [:]
    /// The `Stop` reply.
    @State private var reply: String = ""
    @FocusState private var focus: UUID?
    /// AskUserQuestion state, keyed by question index. Selected labels per
    /// question; whether the Other entry is active; and what it holds.
    @State private var askSelections: [Int: Set<String>] = [:]
    @State private var askOtherActive: Set<Int> = []
    @State private var askOtherEntries: [Int: String] = [:]
    @FocusState private var askFocus: Int?
    @State private var codexSelections: [String: String] = [:]
    @State private var codexOtherQuestions: Set<String> = []
    @State private var codexOtherEntries: [String: String] = [:]
    @FocusState private var codexFocus: String?

    private static let contentWidth: CGFloat = 520
    /// Sentinel focus target for the free-text reply, which has no field id.
    private static let replyFocus = UUID()

    private var accent: Color? { prompt.agent.accent }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            question
            content
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(focusShortcut)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            BrandMark(prompt.agent.logoAsset, size: 12)
                .foregroundStyle(.white.opacity(0.85))
                .opacity(0.85)
            Text(prompt.projectName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
            Text(prompt.agent.displayName)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))

            Spacer()

            if coordinator.waitingCount > 0 {
                Text("\(coordinator.waitingCount) more")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
            }
        }
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(questionTitle)
                // Monospaced only for the tool-and-arguments case. A question
                // is prose and reads badly in a code face.
                .font(titleIsToolName
                      ? .system(.callout, design: .monospaced).weight(.medium)
                      : .body.weight(.medium))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)

            if !prompt.summary.isEmpty {
                Text(prompt.summary)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var questionTitle: String {
        if case .question(let questions) = prompt.kind, questions.count > 1 {
            return "\(prompt.agent.displayName) has \(questions.count) questions"
        }
        guard prompt.event == .userInputRequest else { return prompt.title }
        return prompt.codexQuestions.count > 1
            ? "Codex has \(prompt.codexQuestions.count) questions"
            : (prompt.codexQuestions.first?.question ?? prompt.title)
    }

    /// Only a bare tool permission leads with the tool's name; everything else
    /// leads with a question.
    private var titleIsToolName: Bool {
        if case .permission = prompt.kind { return prompt.event == .permissionRequest }
        return false
    }

    // MARK: Content per kind

    @ViewBuilder
    private var content: some View {
        switch prompt.kind {
        case .permission:
            EmptyView()

        case .question(let questions):
            askQuestionForm(questions)

        case .form(let fields):
            if !fields.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(fields) { field in
                                fieldView(field).id(field.id)
                            }
                        }
                        .padding(.trailing, 2)
                    }
                    // Tall forms scroll rather than growing the panel past its
                    // fixed bounds.
                    .frame(maxHeight: 300)
                    // ⌘L can focus a field below the fold. Without this the
                    // caret lands somewhere the user can't see and typing goes
                    // into a void.
                    .onChange(of: focus) { _, target in
                        guard let target else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
            }

        case .freeText(let placeholder):
            textEntry(text: $reply, placeholder: placeholder, focusID: Self.replyFocus)

        case .externalQuestion:
            codexQuestionForm
        }
    }

    // MARK: AskUserQuestion form

    private func askQuestionForm(_ questions: [AskQuestion]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                        askQuestionView(question, showQuestion: questions.count > 1)
                            .id(question.id)
                        if index < questions.count - 1 {
                            Divider().overlay(.white.opacity(0.08))
                        }
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 340)
            .onChange(of: askFocus) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    private func askQuestionView(_ question: AskQuestion, showQuestion: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if showQuestion {
                Text(question.question)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(question.options) { option in
                askOption(question: question, option: option)
            }
            askOtherOption(question)
        }
    }

    private func askOption(question: AskQuestion, option: AskOption) -> some View {
        let selected = askSelections[question.id, default: []].contains(option.label)
        return Button {
            toggleAskOption(question, label: option.label)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: indicator(isOn: selected, allowsMultiple: question.multiSelect))
                    .font(.caption)
                    .foregroundStyle(selected ? (accent ?? .white) : .white.opacity(0.3))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.75))
                    if let detail = option.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if let shortcut = askShortcut(questionID: question.id, label: option.label) {
                    Text("⌘\(shortcut)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                selected ? (accent ?? .white).opacity(0.16) : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .modifier(OptionShortcut(
            index: askShortcut(questionID: question.id, label: option.label),
            needsCommand: true
        ))
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Claude Code's own picker always offers a free-form entry, so the notch
    /// matches — otherwise an answer the session could take would bounce back
    /// to it.
    private func askOtherOption(_ question: AskQuestion) -> some View {
        let selected = askOtherActive.contains(question.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                toggleAskOther(question)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: indicator(isOn: selected, allowsMultiple: question.multiSelect))
                        .font(.caption)
                        .foregroundStyle(selected ? (accent ?? .white) : .white.opacity(0.3))
                    Text("Other")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.75))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    selected ? (accent ?? .white).opacity(0.16) : Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)

            if selected {
                TextField(
                    "",
                    text: Binding(
                        get: { askOtherEntries[question.id] ?? "" },
                        set: { askOtherEntries[question.id] = $0 }
                    ),
                    prompt: Text("Type your answer").foregroundStyle(.white.opacity(0.28))
                )
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.white)
                .tint(accent ?? .white)
                .padding(9)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .focused($askFocus, equals: question.id)
                .onSubmit(submit)
            }
        }
    }

    private var codexQuestionForm: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(prompt.codexQuestions.enumerated()), id: \.element.id) { index, question in
                        codexQuestionView(question, showQuestion: prompt.codexQuestions.count > 1)
                            .id(question.id)
                        if index < prompt.codexQuestions.count - 1 {
                            Divider().overlay(.white.opacity(0.08))
                        }
                    }
                    codexSubmissionMessage
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 340)
            .onChange(of: codexFocus) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
    }

    private func codexQuestionView(_ question: CodexQuestion, showQuestion: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(question.header)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
            if showQuestion {
                Text(question.question)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(question.options) { option in
                codexOption(question: question, option: option)
            }
            if question.allowsOther {
                codexOtherOption(question)
            }
        }
    }

    private func codexOption(question: CodexQuestion, option: CodexQuestionOption) -> some View {
        let selected = codexSelections[question.id] == option.label
            && !codexOtherQuestions.contains(question.id)
        return Button {
            codexSelections[question.id] = option.label
            codexOtherQuestions.remove(question.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.caption)
                    .foregroundStyle(selected ? (accent ?? .white) : .white.opacity(0.3))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.75))
                    if let detail = option.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if let shortcut = codexShortcut(questionID: question.id, label: option.label) {
                    Text("⌘\(shortcut)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                selected ? (accent ?? .white).opacity(0.16) : Color.white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .modifier(OptionShortcut(
            index: codexShortcut(questionID: question.id, label: option.label),
            needsCommand: true
        ))
        .disabled(codexSubmissionInFlight)
    }

    private func codexOtherOption(_ question: CodexQuestion) -> some View {
        let selected = codexOtherQuestions.contains(question.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                codexOtherQuestions.insert(question.id)
                codexSelections.removeValue(forKey: question.id)
                codexFocus = question.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.caption)
                        .foregroundStyle(selected ? (accent ?? .white) : .white.opacity(0.3))
                    Text("Other")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.75))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    selected ? (accent ?? .white).opacity(0.16) : Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(codexSubmissionInFlight)

            if selected {
                TextField(
                    "",
                    text: Binding(
                        get: { codexOtherEntries[question.id] ?? "" },
                        set: { codexOtherEntries[question.id] = $0 }
                    ),
                    prompt: Text("Type your answer").foregroundStyle(.white.opacity(0.28))
                )
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.white)
                .tint(accent ?? .white)
                .padding(9)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .focused($codexFocus, equals: question.id)
                .disabled(codexSubmissionInFlight)
            }
        }
    }

    @ViewBuilder
    private var codexSubmissionMessage: some View {
        switch coordinator.externalSubmissionState(for: prompt) {
        case .idle:
            EmptyView()
        case .requestingPermission:
            Label("Waiting for Accessibility permission…", systemImage: "hand.raised")
                .font(.caption).foregroundStyle(.orange)
        case .submitting:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Sending to Codex…")
            }
            .font(.caption).foregroundStyle(.white.opacity(0.55))
        case .confirmed:
            Label("Answer received", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func fieldView(_ field: FormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(field.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                if field.isRequired {
                    Text("required")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            if let detail = field.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch field.input {
            case .text(let placeholder):
                textEntry(
                    text: binding(for: field),
                    placeholder: placeholder ?? "",
                    focusID: field.id
                )
            case .number(let isInteger):
                textEntry(
                    text: binding(for: field),
                    placeholder: isInteger ? "whole number" : "number",
                    focusID: field.id
                )
            case .toggle:
                Toggle(isOn: toggleBinding(for: field)) {
                    Text(field.title).font(.callout)
                }
                .toggleStyle(.switch)
                .labelsHidden()
            case .singleSelect(let choices):
                optionList(field: field, choices: choices, allowsMultiple: false)
            case .multiSelect(let choices):
                optionList(field: field, choices: choices, allowsMultiple: true)
            }
        }
    }

    private func optionList(field: FormField, choices: [Choice], allowsMultiple: Bool) -> some View {
        VStack(spacing: 4) {
            ForEach(choices) { choice in
                let isOn = selections[field.id, default: []].contains(choice.value)
                Button {
                    toggle(choice, in: field, allowsMultiple: allowsMultiple)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: indicator(isOn: isOn, allowsMultiple: allowsMultiple))
                            .font(.caption)
                            .foregroundStyle(isOn ? (accent ?? .white) : .white.opacity(0.3))
                        Text(choice.label)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(isOn ? 0.95 : 0.7))
                        Spacer(minLength: 4)
                        if let index = shortcutIndex(for: choice) {
                            Text(shortcutLabel(index))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        (isOn ? (accent ?? .white).opacity(0.16) : Color.white.opacity(0.05)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .modifier(OptionShortcut(index: shortcutIndex(for: choice), needsCommand: prompt.kind.hasTextEntry))
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }

    private func indicator(isOn: Bool, allowsMultiple: Bool) -> String {
        if allowsMultiple {
            return isOn ? "checkmark.square.fill" : "square"
        }
        return isOn ? "largecircle.fill.circle" : "circle"
    }

    private func textEntry(text: Binding<String>, placeholder: String, focusID: UUID) -> some View {
        TextField(
            "",
            text: text,
            prompt: Text(placeholder).foregroundStyle(.white.opacity(0.28))
        )
        .textFieldStyle(.plain)
        .font(.callout)
        .foregroundStyle(.white)
        .tint(accent ?? .white)
        .padding(9)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    focus == focusID ? (accent ?? .white).opacity(0.55) : .white.opacity(0.08),
                    lineWidth: 1
                )
        )
        .focused($focus, equals: focusID)
        .onSubmit(submit)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            switch prompt.kind {
            case .permission:
                choice("Allow", shortcut: "1", emphasis: 1.0) {
                    coordinator.resolve(prompt, with: .permission(.allow))
                }
                choice("Deny", shortcut: "2", emphasis: 0.45) {
                    coordinator.resolve(prompt, with: .permission(.deny))
                }
            case .question:
                choice("Send", shortcut: nil, emphasis: 1.0, enabled: askAnswersComplete, action: submitAskAnswers)
                choice("Open Claude", shortcut: nil, emphasis: 0.35, action: openClaude)
            case .form:
                choice("Send", shortcut: nil, emphasis: 1.0, enabled: requiredSatisfied, action: submit)
                choice("Decline", shortcut: nil, emphasis: 0.45) {
                    coordinator.resolve(prompt, with: .form(action: .decline, values: [:]))
                }
            case .freeText:
                choice("Send", shortcut: nil, emphasis: 1.0,
                       enabled: !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       action: submit)
            case .externalQuestion:
                choice(
                    codexSubmissionInFlight ? "Sending…" : "Send",
                    shortcut: nil,
                    emphasis: 1.0,
                    enabled: codexAnswersComplete && !codexSubmissionInFlight,
                    action: submitCodexAnswers
                )
                choice("Open Codex", shortcut: nil, emphasis: 0.35, action: openCodex)
            }

            Spacer()

            Button(secondaryActionTitle) { dismiss() }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.4))
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel(prompt.event == .stop
                                    ? "End the turn without replying"
                                    : "Dismiss without answering")
        }
    }

    /// `emphasis` keeps the primary and secondary actions distinguishable when
    /// they share an accent: both render in the agent's colour with white text,
    /// but the secondary sits back at a lower fill so the pair doesn't read as
    /// two identical buttons.
    private func choice(
        _ title: String,
        shortcut: Character?,
        emphasis: Double,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let shortcut {
                    Text(String(shortcut))
                        .font(.caption2.monospaced())
                        .opacity(0.55)
                }
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(accent == nil ? Color.white.opacity(0.4 + 0.6 * emphasis) : .white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                (accent ?? .white).opacity(accent == nil ? 0.1 : emphasis),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .modifier(PlainKeyShortcut(key: shortcut))
        .accessibilityLabel(title)
    }

    /// ⌘L focuses the first text entry, per §4.
    private var focusShortcut: some View {
        Button("") { focus = firstTextFocusID }
            .keyboardShortcut("l", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    // MARK: Interaction

    private func submit() {
        switch prompt.kind {
        case .permission:
            coordinator.resolve(prompt, with: .permission(.allow))
        case .question:
            submitAskAnswers()
        case .form(let fields):
            guard requiredSatisfied else { return }
            coordinator.resolve(prompt, with: .form(action: .accept, values: values(of: fields)))
        case .freeText:
            coordinator.resolve(prompt, with: .text(reply))
        case .externalQuestion:
            submitCodexAnswers()
        }
    }

    // MARK: AskUserQuestion interaction

    private func toggleAskOption(_ question: AskQuestion, label: String) {
        var chosen = askSelections[question.id, default: []]
        if question.multiSelect {
            if chosen.contains(label) { chosen.remove(label) } else { chosen.insert(label) }
        } else {
            chosen = chosen.contains(label) ? [] : [label]
            askOtherActive.remove(question.id)
        }
        askSelections[question.id] = chosen
    }

    private func toggleAskOther(_ question: AskQuestion) {
        if askOtherActive.contains(question.id) {
            askOtherActive.remove(question.id)
            return
        }
        askOtherActive.insert(question.id)
        if !question.multiSelect { askSelections[question.id] = [] }
        askFocus = question.id
    }

    /// Every question needs a selection or a non-empty Other before Send lights
    /// up — a half-answered multi-question ask would put words in the model's
    /// mouth for the questions the user skipped.
    private var askAnswersComplete: Bool {
        guard case .question(let questions) = prompt.kind else { return false }
        return questions.allSatisfy { question in
            if askOtherActive.contains(question.id),
               !(askOtherEntries[question.id] ?? "")
                   .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return !askSelections[question.id, default: []].isEmpty
        }
    }

    private func submitAskAnswers() {
        guard case .question(let questions) = prompt.kind, askAnswersComplete else { return }
        let answers = questions.map { question -> AskAnswer in
            let chosen = askSelections[question.id, default: []]
            let other = askOtherActive.contains(question.id)
                ? askOtherEntries[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            return AskAnswer(
                question: question,
                selectedLabels: question.options.map(\.label).filter { chosen.contains($0) },
                otherText: (other?.isEmpty == false) ? other : nil
            )
        }
        coordinator.resolve(prompt, with: .answers(answers))
    }

    private func askShortcut(questionID: Int, label: String) -> Int? {
        guard case .question(let questions) = prompt.kind else { return nil }
        let flattened = questions.flatMap { question in
            question.options.map { (question.id, $0.label) }
        }
        guard let index = flattened.firstIndex(where: { $0.0 == questionID && $0.1 == label }),
              index < 9 else { return nil }
        return index + 1
    }

    private var codexSubmissionInFlight: Bool {
        switch coordinator.externalSubmissionState(for: prompt) {
        case .requestingPermission, .submitting, .confirmed: return true
        case .idle, .failed: return false
        }
    }

    private var codexAnswersComplete: Bool {
        !prompt.codexQuestions.isEmpty && prompt.codexQuestions.allSatisfy { question in
            if codexOtherQuestions.contains(question.id) {
                return !(codexOtherEntries[question.id] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return codexSelections[question.id] != nil
        }
    }

    private func submitCodexAnswers() {
        guard codexAnswersComplete else { return }
        let answers = prompt.codexQuestions.map { question in
            if codexOtherQuestions.contains(question.id) {
                return CodexQuestionAnswer(
                    questionID: question.id,
                    selectedLabel: nil,
                    otherText: codexOtherEntries[question.id]?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return CodexQuestionAnswer(
                questionID: question.id,
                selectedLabel: codexSelections[question.id],
                otherText: nil
            )
        }
        coordinator.submitExternal(prompt, answers: answers)
    }

    private func codexShortcut(questionID: String, label: String) -> Int? {
        let flattened = prompt.codexQuestions.flatMap { question in
            question.options.map { (question.id, $0.label) }
        }
        guard let index = flattened.firstIndex(where: { $0.0 == questionID && $0.1 == label }),
              index < 9 else { return nil }
        return index + 1
    }

    private var secondaryActionTitle: String {
        switch prompt.kind {
        case .freeText: return "End turn"
        case .externalQuestion: return "Dismiss"
        case .permission, .question, .form: return "Later"
        }
    }

    /// Fronts the Claude desktop app and allows the call, which turns the
    /// session's own picker into the live surface — the escape hatch when the
    /// notch is the wrong place to think about a question. A terminal session
    /// still unblocks; there's just no window to bring forward.
    private func openClaude() {
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        ).first {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.anthropic.claudefordesktop"
        ) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        coordinator.resolve(prompt, with: .permission(.allow))
    }

    private func openCodex() {
        if let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex"
        ).first {
            app.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        // This resolves only the notch card. Codex remains blocked until the
        // user answers in the owning desktop client.
        coordinator.resolve(prompt, with: .permission(.allow))
    }

    private func dismiss() {
        // An empty reply to Stop is a real answer — "nothing more" — so let the
        // turn end instead of re-queueing the prompt forever.
        if case .freeText = prompt.kind {
            coordinator.resolve(prompt, with: .text(""))
        } else if case .externalQuestion = prompt.kind {
            coordinator.resolve(prompt, with: .permission(.deny))
        } else {
            coordinator.dismissCurrent()
        }
    }

    private func toggle(_ choice: Choice, in field: FormField, allowsMultiple: Bool) {
        var chosen = selections[field.id, default: []]
        if allowsMultiple {
            if chosen.contains(choice.value) { chosen.remove(choice.value) } else { chosen.insert(choice.value) }
        } else {
            chosen = chosen.contains(choice.value) ? [] : [choice.value]
        }
        selections[field.id] = chosen
    }

    private func binding(for field: FormField) -> Binding<String> {
        Binding(
            get: { entries[field.id] ?? "" },
            set: { entries[field.id] = $0 }
        )
    }

    private func toggleBinding(for field: FormField) -> Binding<Bool> {
        Binding(
            get: { selections[field.id, default: []].contains("true") },
            set: { selections[field.id] = $0 ? ["true"] : [] }
        )
    }

    /// Collects field values into the `content` object the elicitation response
    /// expects, typed per the field's input so numbers and booleans don't go
    /// back as strings.
    private func values(of fields: [FormField]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for field in fields {
            switch field.input {
            case .text:
                let text = entries[field.id] ?? ""
                if !text.isEmpty { result[field.name] = .string(text) }
            case .number(let isInteger):
                let text = entries[field.id] ?? ""
                if let number = Double(text) {
                    result[field.name] = .number(isInteger ? number.rounded() : number)
                }
            case .toggle:
                result[field.name] = .bool(selections[field.id, default: []].contains("true"))
            case .singleSelect:
                if let value = selections[field.id, default: []].first {
                    result[field.name] = .string(value)
                }
            case .multiSelect(let choices):
                // Preserve the schema's order rather than Set iteration order.
                let chosen = selections[field.id, default: []]
                let ordered = choices.filter { chosen.contains($0.value) }.map { JSONValue.string($0.value) }
                if !ordered.isEmpty { result[field.name] = .array(ordered) }
            }
        }
        return result
    }

    private var requiredSatisfied: Bool {
        guard case .form(let fields) = prompt.kind else { return true }
        return fields.allSatisfy { field in
            guard field.isRequired else { return true }
            switch field.input {
            case .text, .number:
                return !(entries[field.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            case .toggle:
                return true
            case .singleSelect, .multiSelect:
                return !selections[field.id, default: []].isEmpty
            }
        }
    }

    // MARK: Keyboard mapping

    /// Every choice across every field, numbered 1…9 in render order.
    private var numberedChoices: [Choice] {
        guard case .form(let fields) = prompt.kind else { return [] }
        return fields.flatMap { field -> [Choice] in
            switch field.input {
            case .singleSelect(let choices), .multiSelect(let choices): return choices
            default: return []
            }
        }
    }

    private func shortcutIndex(for choice: Choice) -> Int? {
        guard let position = numberedChoices.firstIndex(where: { $0.id == choice.id }), position < 9 else {
            return nil
        }
        return position + 1
    }

    /// Bare digits would be swallowed by a text field, so forms containing one
    /// move their option shortcuts onto ⌘.
    private func shortcutLabel(_ index: Int) -> String {
        prompt.kind.hasTextEntry ? "⌘\(index)" : "\(index)"
    }

    private var firstTextFocusID: UUID? {
        switch prompt.kind {
        case .freeText: return Self.replyFocus
        case .form(let fields):
            return fields.first {
                switch $0.input {
                case .text, .number: return true
                default: return false
                }
            }?.id
        case .permission, .question, .externalQuestion: return nil
        }
    }
}

/// A record on a turntable: album art in a circular cutout, turning slowly.
private struct SpinningDisc: View {
    let image: NSImage?
    let isSpinning: Bool
    let size: CGFloat

    @State private var angle: Double = 0

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.08))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(.white.opacity(0.4))
            }
            // Spindle hole, so the rotation actually reads as rotation on
            // artwork that has no strong orientation.
            Circle()
                .fill(.black.opacity(0.6))
                .frame(width: size * 0.24, height: size * 0.24)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
        .rotationEffect(.degrees(angle))
        .task(id: isSpinning) {
            guard isSpinning else { return }
            // Advanced by hand rather than with `repeatForever` so pausing
            // freezes the disc where it stands instead of snapping it upright.
            // ~9s per revolution at 25fps.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                angle = (angle + 1.6).truncatingRemainder(dividingBy: 360)
            }
        }
    }
}

// MARK: - Shortcut modifiers

/// `keyboardShortcut` takes a non-optional key, so the optional cases need a
/// modifier rather than an inline conditional.
private struct PlainKeyShortcut: ViewModifier {
    let key: Character?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: [])
        } else {
            content
        }
    }
}

private struct OptionShortcut: ViewModifier {
    let index: Int?
    let needsCommand: Bool

    func body(content: Content) -> some View {
        if let index, let key = Character("\(index)").asKeyEquivalent {
            content.keyboardShortcut(key, modifiers: needsCommand ? .command : [])
        } else {
            content
        }
    }
}

private extension Character {
    var asKeyEquivalent: KeyEquivalent? { KeyEquivalent(self) }
}

private extension Agent {
    /// Claude Code answers in its own orange; Codex stays neutral. That the two
    /// look different is the point — with both connectors live, the colour is a
    /// pre-attentive tell of which agent you're about to unblock.
    var accent: Color? {
        switch self {
        case .claudeCode: return Color(red: 0.851, green: 0.467, blue: 0.341)
        case .codex: return nil
        }
    }
}
