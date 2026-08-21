//
//  NotchUI.swift
//  notch-911
//
//  The pieces every surface in the notch draws the same way.
//
//  There was no design-system file here before, and for six surfaces there
//  didn't need to be — five near-identical heading rows is a smell, not a bug.
//  A tabbed surface changes the arithmetic: the tab bar, the session rows and
//  the media and tools tabs would have added a seventh, eighth and ninth copy
//  of the same chip and the same heading.
//
//  So: the shared pieces, with the existing conventions written down rather
//  than re-derived. The white-opacity ladder in particular is load-bearing —
//  everything in the notch is white on black, and depth is opacity alone.
//
//  These are used by the new surfaces. The five existing headings are left
//  alone deliberately: migrating them is a mechanical follow-up, and mixing it
//  into this change would bury the parts that alter behaviour.
//

import SwiftUI

// MARK: - The ladder

/// The opacities the notch is built out of, named. Every value here already
/// appears a dozen times across the surfaces; nothing is new.
nonisolated enum NotchInk {
    /// Body text you are meant to read.
    static let primary: Double = 0.9
    /// Present, but not the point.
    static let secondary: Double = 0.6
    /// Headings, chips at rest, the frame around things.
    static let tertiary: Double = 0.45
    /// Footer hints. Deliberately near the floor of legibility — these are for
    /// the second time you use a surface, not the first.
    static let hint: Double = 0.25
    /// Resting fill under a chip or a row.
    static let fill: Double = 0.08
    /// The same, under the pointer.
    static let fillHover: Double = 0.14
    /// A row that is selected rather than hovered.
    static let fillSelected: Double = 0.16
}

// MARK: - Heading

/// The row every non-peek surface opens with: back chevron, glyph, title, and
/// whatever that surface wants on the right.
///
/// `onBack` is optional because not every surface has somewhere to go back to —
/// but the ones that do all draw the chevron identically, down to the 16pt hit
/// area that stops it being a 6pt target in the corner of the panel.
struct SurfaceHeading<Trailing: View>: View {
    let glyph: String
    let title: String
    var onBack: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 4) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            Image(systemName: glyph)
            Text(title)
            Spacer(minLength: 0)
            trailing
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(NotchInk.tertiary))
    }
}

extension SurfaceHeading where Trailing == EmptyView {
    init(glyph: String, title: String, onBack: (() -> Void)? = nil) {
        self.init(glyph: glyph, title: title, onBack: onBack) { EmptyView() }
    }
}

/// The keyboard legend at the bottom of a surface.
func notchFooterHint(_ text: String) -> some View {
    Text(text)
        .font(.caption2)
        .foregroundStyle(.white.opacity(NotchInk.hint))
}

// MARK: - Chip

/// The capsule button the peek header is made of, with its own hover state.
///
/// `PeekCard` carries five `@State ...Hovered` bools for five of these; owning
/// the state here is what stops the tab bar adding three more.
struct NotchChip<Label: View>: View {
    var isSelected = false
    let action: () -> Void
    @ViewBuilder var label: Label

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(foreground))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.white.opacity(background), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }

    private var foreground: Double {
        if isSelected { return 0.95 }
        return hovered ? 0.75 : NotchInk.tertiary
    }

    private var background: Double {
        if isSelected { return NotchInk.fillHover }
        return hovered ? NotchInk.fillHover : NotchInk.fill
    }
}

// MARK: - Row

/// A tappable row on a surface: rounded rect, quiet at rest, lighter under the
/// pointer, lighter still when selected. The clipboard and the ask-question
/// options both draw this; the tabs draw it three more times.
struct NotchRow<Content: View>: View {
    var isSelected = false
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    @State private var hovered = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { body(for: content) }
                    .buttonStyle(.plain)
            } else {
                body(for: content)
            }
        }
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.14), value: hovered)
    }

    private func body(for content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .white.opacity(fill),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
    }

    private var fill: Double {
        if isSelected { return NotchInk.fillSelected }
        return hovered ? 0.1 : 0.05
    }
}

// MARK: - Connector status

/// The Claude Code / Codex dots. Lifted out of `PeekCard` so the Agents tab
/// answers "is this even wired up" with the same row the peek does, rather than
/// a second one that could disagree with it.
struct ConnectorRow: View {
    let status: PromptCoordinator.AgentStatus

    var body: some View {
        HStack(spacing: 12) {
            dot("Claude Code", on: status.claudeConnected)
            dot("Codex", on: status.codexConnected)
            Spacer()
            if let port = status.port {
                Text(":\(String(port))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(NotchInk.hint))
            }
        }
    }

    private func dot(_ name: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on ? Color.green.opacity(0.8) : Color.white.opacity(0.2))
                .frame(width: 5, height: 5)
            Text(name)
                .font(.caption2)
                .foregroundStyle(.white.opacity(on ? 0.5 : NotchInk.hint))
        }
    }
}

// MARK: - Now playing

/// Album art at whatever size the caller needs, with a placeholder that holds
/// the same footprint so nothing reflows when the image lands a moment after
/// the track data.
struct NowPlayingCover: View {
    let media: MediaMonitor
    var size: CGFloat

    var body: some View {
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
                    .foregroundStyle(.white.opacity(NotchInk.hint))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.22), value: media.artwork != nil)
    }
}

/// Previous / play-pause / next, sized to whatever column it sits in.
struct NowPlayingTransport: View {
    let media: MediaMonitor
    let track: MediaController.NowPlaying
    var width: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            button("backward.fill", label: "Previous track") { media.previous() }
            button(
                track.isPlaying ? "pause.fill" : "play.fill",
                label: track.isPlaying ? "Pause" : "Play"
            ) { media.playPause() }
            button("forward.fill", label: "Next track") { media.next() }
        }
        .frame(width: width)
    }

    private func button(
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
}

/// The thin elapsed bar. Position only refreshes once a second, so it is eased
/// to stop the bar stepping.
struct NowPlayingProgress: View {
    let track: MediaController.NowPlaying

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(.white.opacity(0.5))
                    .frame(width: proxy.size.width * NotchTime.fraction(track))
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.9), value: track.position)
    }
}

/// Clock formatting shared by the peek and the Media tab.
nonisolated enum NotchTime {
    static func fraction(_ track: MediaController.NowPlaying) -> Double {
        guard track.duration > 0 else { return 0 }
        return min(1, max(0, track.position / track.duration))
    }

    static func label(_ track: MediaController.NowPlaying) -> String {
        "\(clock(track.position)) / \(clock(track.duration))"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "just now", "4m", "2h" — for a session's last activity. Short because it
    /// sits at the end of a row that already carries a project and a branch.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

// MARK: - Shared shortcut and accent

/// `keyboardShortcut` takes a non-optional key, so the optional cases need a
/// modifier rather than an inline conditional.
///
/// Lives here rather than beside `OptionShortcut` in `NotchPanel` because both
/// prompt cards need it, and two copies of a keyboard mapping is how two cards
/// end up disagreeing about what `1` does.
struct PlainKeyShortcut: ViewModifier {
    let key: Character?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: [])
        } else {
            content
        }
    }
}

extension Agent {
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

// MARK: - Counter

/// One number and what it counts, for the row of them across the top of Home.
///
/// Display-only, deliberately. A tile that is sometimes tappable and sometimes
/// not is a worse control than one that never is — the rows underneath are the
/// interactive part of that surface.
struct NotchStat: View {
    let value: Int
    let label: String
    /// `nil` keeps it on the usual white ladder. A tint is for a count that
    /// means something the moment it stops being zero.
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.title3.weight(.medium).monospacedDigit())
                .foregroundStyle(tint ?? .white.opacity(NotchInk.primary))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(NotchInk.tertiary))
        }
        // A floor rather than a fixed width: the row must not re-flow when a
        // count crosses from 9 to 10, and must still fit "Answered".
        .frame(minWidth: 64, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            .white.opacity(NotchInk.fill),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

// MARK: - A blocked prompt

/// One prompt still waiting on an answer, with the way back to it.
///
/// Extracted from `PeekCard`, which had hand-rolled it; Home needs the same row
/// and a fourth copy of it was not worth writing. Both callers lay it out with a
/// `Spacer`, so it takes the peek's 284pt column and Home's ~544pt without
/// either needing a variant of its own.
struct StrandedRow: View {
    let prompt: Prompt
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
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
                        .foregroundStyle(.white.opacity(NotchInk.tertiary))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("Resume")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                .white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(prompt.projectName), \(prompt.title)")
    }
}
