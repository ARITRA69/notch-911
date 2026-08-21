//
//  ClipboardCard.swift
//  notch-911
//
//  The clipboard surface: thirty rows, newest at the top, click or ↵ to put one
//  back on the pasteboard.
//
//  A vertical list rather than a horizontal strip of cards. Cards photograph
//  better and fail every requirement here — thirty of them at ~140pt is thirty
//  viewports of horizontal scroll in a 640pt window, trackpad horizontal scroll
//  fights swipe-between-pages, a narrow card can't show a readable snippet, and
//  both arrow-key navigation and per-row hover-delete want a column.
//

import AppKit
import SwiftUI

/// Reports the pointer's position over a view, in top-left coordinates, or nil
/// when it leaves.
///
/// This exists because SwiftUI's own hover modifiers stop delivering inside the
/// clipboard list — see the call site. Tracking areas are region-based rather
/// than hit-test based, so this keeps working with the rows drawn on top of it.
///
/// `hitTest` returns nil on purpose: the view sits in an `.overlay`, above the
/// rows, so that it is unambiguously in the tracking path — but it must stay
/// invisible to clicks, or it would swallow every press meant for a row.
private struct PointerTracker: NSViewRepresentable {
    var onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onMove = onMove
    }

    final class TrackingView: NSView {
        var onMove: ((CGPoint?) -> Void)?
        private var tracking: NSTrackingArea?

        /// Matches SwiftUI's top-left origin, so the caller's row arithmetic
        /// doesn't have to flip anything.
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            // `.inVisibleRect` keeps the area in step with scrolling and resize
            // on its own, so this only ever runs on real geometry changes.
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { onMove?(nil) }

        private func report(_ event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil))
        }
    }
}

struct ClipboardCard: View {
    let store: ClipboardStore
    let coordinator: PromptCoordinator

    @State private var selection: ClipItem.ID?
    @State private var hovered: ClipItem.ID?
    /// Set only by keyboard navigation. Scrolling is driven off this rather than
    /// off `selection`, because the pointer sets `selection` too — and a list
    /// that re-centres the row you are merely *pointing at* slides a different
    /// row under a stationary cursor, which fires `onHover` again and makes the
    /// whole surface chase the mouse.
    @State private var scrollTarget: ClipItem.ID?

    /// Uniform rows: a 32pt thumbnail beside two lines of `.callout` is exactly
    /// 44, so every kind lands on the same rhythm and arrow-key scrolling
    /// doesn't stutter over ragged heights.
    private static let row: CGFloat = 44
    private static let gap: CGFloat = 4
    private static let glyph: CGFloat = 32

    /// The panel is fixed at 620pt and never resized. Budgeting down from the
    /// top: notch inset + 8 (46), heading (14), spacing (8), this, spacing (8),
    /// footer (13), bottom padding (16) — then the shadow's offset and clamped
    /// radius (44) have to fit too. That leaves 471; 420 keeps 45pt of slack for
    /// a Mac reporting a fatter `safeAreaInsets.top`.
    private static let listHeight: CGFloat = 420

    /// The same spring `ShelfView` opens with. Deliberately identical — the two
    /// surfaces belong to one app and shouldn't move to different rhythms.
    private static let reveal = Animation.spring(response: 0.34, dampingFraction: 0.84)

    private var selectedItem: ClipItem? {
        store.items.first { $0.id == selection }
    }

    /// A `ScrollView` is greedy: given `maxHeight` it takes all of it, so four
    /// clips would hang the surface open over 200pt of empty black with the
    /// footer stranded at the bottom. Rows are a uniform `row` tall with a `gap`
    /// between, so the natural height is exact arithmetic and needs no
    /// measurement pass — which is the second thing uniform rows buy, after
    /// arrow-key scrolling that doesn't stutter.
    private var scrollHeight: CGFloat {
        let count = CGFloat(store.items.count)
        guard count > 0 else { return 0 }
        return min(Self.listHeight, count * Self.row + (count - 1) * Self.gap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            if store.items.isEmpty { empty } else { scroller }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shortcuts)
        .onAppear {
            selection = store.items.first?.id
            // Once per opening, off the main actor — a file clip can go stale
            // between openings, but checking that per render costs a stat().
            store.refreshFileStates()
        }
    }

    // MARK: Heading and footer

    private var heading: some View {
        HStack(spacing: 4) {
            // Back to the peek, mirroring the chip that led here. Shown even
            // when the surface was opened by ⇧⌘V — the peek is the idle hub,
            // so "back" always has somewhere sensible to go.
            Button { coordinator.back() } label: {
                Image(systemName: "chevron.left")
                    // The glyph alone is a ~6pt target at the corner of the
                    // panel; pad the hit area without moving the layout.
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the notch overview")
            Image(systemName: store.items.isEmpty ? "doc.on.clipboard" : "doc.on.clipboard.fill")
            Text(store.items.isEmpty ? "Clipboard" : "\(store.items.count)/\(ClipboardStore.maxItems)")
            Spacer(minLength: 0)
            if !store.items.isEmpty {
                Button {
                    withAnimation(Self.reveal) { store.removeAll() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the clipboard history")
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.35))
    }

    private var footer: some View {
        Text("↵ copy · ⌫ remove · ⎋ close")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.25))
    }

    private var empty: some View {
        Text(store.isCapturing
             ? "Nothing copied yet."
             : "Clipboard history is off — turn it on in notch-911's window.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.4))
            .frame(height: Self.row, alignment: .leading)
    }

    // MARK: List

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                list.padding(.trailing, 2)   // keeps content off the overlay scroller
            }
            .frame(height: scrollHeight)
            .animation(Self.reveal, value: scrollHeight)
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
            }
            .onChange(of: store.items.first?.id) { _, newest in
                // A new clip always pulls you back to the top: the top is the
                // thing you just copied, and leaving the viewport parked
                // mid-list makes the insertion look like the list jumped a row.
                guard let newest else { return }
                selection = newest
                scrollTarget = newest
                withAnimation(Self.reveal) { proxy.scrollTo(newest, anchor: .top) }
            }
        }
    }

    /// Eager, like `ShelfView.grid`, and for a related but not identical reason.
    /// The container's own appearance is handled by `contentFade` here, so
    /// laziness wouldn't break *that* — but a `LazyVStack` inside a `ScrollView`
    /// re-creates rows as they scroll into view, and SwiftUI replays each row's
    /// insertion `.transition` when it does. The list would appear to animate
    /// continuously while you scrolled it. At `maxItems = 30` the eager cost is
    /// one layout pass over thirty fixed-height rows; the cap is what makes that
    /// a safe trade, exactly as `ShelfStore.maxItems` does at nine.
    private var list: some View {
        VStack(spacing: Self.gap) {
            // `store.items` is newest-first by contract — no `.reversed()`.
            ForEach(store.items) { item in
                row(item)
                    .id(item.id)
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(Self.reveal, value: store.items.count)
        // One tracking area for the whole column, and ours rather than SwiftUI's.
        //
        // Neither SwiftUI hover modifier survives this list. Per-row `.onHover`
        // dies the moment a row rebuilds to show its ✕ — AppKit never delivers
        // another enter/exit for that row, so the highlight sticks to whichever
        // row you touched first. `.onContinuousHover` on the column fares no
        // better: it reports two or three moves and then sends `.ended` while
        // the pointer is still well inside, and never resumes. That was measured
        // with the handler mutating no state at all, so it isn't re-render
        // churn — it's the tracking area underneath, which SwiftUI gives us no
        // way to reach.
        //
        // `PointerTracker` owns an `NSTrackingArea` directly and keeps
        // reporting. Rows are a uniform height, so the row under the pointer is
        // arithmetic — the third thing uniform rows buy, after unstuttering
        // arrow-key scrolling and an exact `scrollHeight`. The gap above each
        // row counts as part of it, so crossing a boundary can't flicker
        // through "nothing hovered".
        .overlay(
            PointerTracker { point in
                guard let point else {
                    hovered = nil
                    return
                }
                let index = Int(point.y / (Self.row + Self.gap))
                guard store.items.indices.contains(index) else {
                    hovered = nil
                    return
                }
                let id = store.items[index].id
                guard hovered != id else { return }
                hovered = id
                selection = id
            }
        )
    }

    private func row(_ item: ClipItem) -> some View {
        let isSelected = selection == item.id
        let isHovered = hovered == item.id
        let isStale = store.isStale(item)
        let isJustCopied = store.justCopied == item.id
        let preview = store.preview(for: item)

        return Button { activate(item) } label: {
            HStack(spacing: 10) {
                thumbnail(item)
                    .frame(width: Self.glyph, height: Self.glyph)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(isStale ? 0.4 : 1)

                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(isStale ? 0.4 : (isSelected ? 0.95 : 0.8)))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                // Meta rides the trailing edge rather than sitting under the
                // preview: stacked, it would cost the text its second line and
                // push every row past 44.
                HStack(spacing: 5) {
                    if isJustCopied {
                        Text("Copied")
                            .transition(.opacity)
                    } else {
                        if let icon = store.sourceIcon(for: item) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 11, height: 11)
                        }
                        Text(isStale ? "Missing" : item.kind.label)
                    }
                }
                .font(.caption2)
                .foregroundStyle(isStale ? Color.orange.opacity(0.7) : .white.opacity(0.35))

                // Space reserved for the delete button, which lives *outside*
                // this label — see the overlay below.
                Color.clear.frame(width: 18)
            }
            .padding(.horizontal, 9)
            .frame(height: Self.row)
            .background(
                isSelected ? Color.white.opacity(0.10)
                           : (isHovered ? Color.white.opacity(0.05) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        // Hover-reveal delete, same symbol as `ShelfView.tile` — and, as there,
        // an *overlay* rather than something nested inside the row button's
        // label. A Button inside another Button's label doesn't reliably win the
        // click on macOS, and losing that race here would mean the X copied the
        // clip and collapsed the panel instead of deleting it.
        .overlay(alignment: .trailing) {
            if isHovered {
                Button {
                    withAnimation(Self.reveal) { store.remove(item) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white.opacity(0.85), .white.opacity(0.18))
                        // A larger transparent hit area than the glyph, so the
                        // target isn't a 13pt circle at the edge of the panel.
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Remove this clipping")
            }
        }
        // No `.onHover` here — see `list`, which tracks the pointer for the
        // whole column.
        // Keyed on this row's own booleans, not on the card-level `hovered` /
        // `selection`. Keyed on those, moving the pointer one row re-ran the
        // animation on all thirty rows at once — two full list-wide animation
        // passes per crossing, which is what made the highlight feel like it
        // was dragging itself along behind the cursor.
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .animation(.easeOut(duration: 0.14), value: isJustCopied)
        // No `.help()`. Its tooltip gets stranded over the list — the pointer is
        // tracked by an overlay that reports nil from `hitTest`, so AppKit's
        // tooltip machinery never learns the pointer moved on, and a stale
        // filename hangs over the rows. The two-line preview is the tooltip.
        .accessibilityLabel("\(item.kind.label): \(preview)")
    }

    @ViewBuilder
    private func thumbnail(_ item: ClipItem) -> some View {
        // Cached by the store. Resolving a Finder icon here would put a Launch
        // Services call on every hover.
        if let image = store.rowImage(for: item) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: item.kind == .files ? .fit : .fill)
        } else {
            ZStack {
                Color.white.opacity(0.06)
                Image(systemName: item.kind.symbol)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    // MARK: Interaction

    private func activate(_ item: ClipItem) {
        // A row whose payload has gone missing leaves the pasteboard alone and
        // stays on screen — collapsing the notch would look like it worked.
        guard store.copy(item) else { return }
        // Collapse, don't paste. The clipboard is now primed and the user's own
        // ⌘V is the paste — synthesising one would need Accessibility, which
        // this feature exists specifically to not need.
        coordinator.closeClipboard()
    }

    private func activate(index: Int) {
        guard store.items.indices.contains(index) else { return }
        activate(store.items[index])
    }

    private func move(_ delta: Int) {
        guard !store.items.isEmpty else { return }
        let current = store.items.firstIndex { $0.id == selection } ?? -1
        // Clamped, not wrapped: wrapping from the bottom to the top of a
        // three-viewport list teleports the viewport and loses the user.
        let next = min(max(current + delta, 0), store.items.count - 1)
        selection = store.items[next].id
        scrollTarget = selection
    }

    private func deleteSelected() {
        guard let item = selectedItem else { return }
        let index = store.items.firstIndex { $0.id == item.id }
        withAnimation(Self.reveal) { store.remove(item) }
        // Keep the cursor where the eye already is rather than dumping it back
        // at the top of the list.
        if let index {
            selection = store.items.indices.contains(index)
                ? store.items[index].id
                : store.items.last?.id
        }
    }

    /// `keyboardShortcut` has to hang off a control in the key window's
    /// responder chain, and none of these should be visible or tabbable — so
    /// they're zero-size buttons behind the card, the same trick `PromptCard`
    /// uses for ⌘L. This only works because `setVisible` makes the panel key for
    /// this surface; the peek, which never becomes key, could not do it.
    private var shortcuts: some View {
        ZStack {
            Button("") { coordinator.closeClipboard() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("") { move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { move(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("") { if let item = selectedItem { activate(item) } }
                .keyboardShortcut(.return, modifiers: [])
            Button("") { deleteSelected() }
                .keyboardShortcut(.delete, modifiers: [])
            // ⌘1…⌘9 straight to the nine newest — the same numbered-choice idea
            // as the prompt card, and the whole point of the surface is not
            // having to aim at anything. On ⌘ rather than bare digits so a
            // filter field can land later without re-mapping them.
            ForEach(1...9, id: \.self) { n in
                Button("") { activate(index: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
