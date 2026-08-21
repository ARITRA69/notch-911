//
//  PlanCard.swift
//  notch-911
//
//  The card for `ExitPlanMode` — the one prompt the generic allow/deny surface
//  served worst.
//
//  Before this, a plan arrived as a bare tool name over `ToolSummary.lead`'s
//  fallback: no `command`, `file_path`, `url`, `path` or `query` key in the
//  input, so it fell through to `prettyPrinted()` and dumped the whole plan as
//  escaped JSON into a four-line monospaced box, under two buttons reading
//  Allow and Deny. A plan is the longest and most considered thing an agent
//  ever hands you, and it was the least readable thing in the app.
//
//  The buttons are Claude Code's own, because this is Claude Code's question
//  and answering it in the notch should not mean answering a different one:
//
//    Yes, and auto-accept edits
//    Yes, and manually approve edits
//    No, keep planning
//
//  "Keep planning" carries the feedback field when it has anything in it. That
//  is the same channel `AskAnswer.denyMessage` uses — the deny message is the
//  only place in the `PermissionRequest` schema where a user's words reach the
//  model — and it is why a revision request works at all here.
//
//  Auto-accept is the one button with a side effect beyond the answer: it sets
//  this session's `PermissionPolicy` to `.acceptEdits`, so the promise the
//  button makes is kept by the hook rather than by hope.
//

import SwiftUI

struct PlanCard: View {
    let prompt: Prompt
    let markdown: String
    let filePath: String?
    let coordinator: PromptCoordinator

    @State private var feedback: String = ""
    @FocusState private var focused: Bool

    private var accent: Color? { prompt.agent.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            plan
            feedbackField
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
            Text("Plan")
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

    // MARK: The plan

    private var plan: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ready to code?")
                .font(.body.weight(.medium))
                .foregroundStyle(.white.opacity(0.95))

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(PlanMarkdown.blocks(markdown).enumerated()), id: \.offset) { item in
                        line(item.element)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 300)
            .scrollIndicators(.never)
            .padding(10)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let filePath, !filePath.isEmpty {
                Text((filePath as NSString).lastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(NotchInk.hint))
            }
        }
    }

    @ViewBuilder
    private func line(_ block: PlanMarkdown.Block) -> some View {
        switch block {
        case .heading(let text, let level):
            Text(text)
                .font(level <= 2 ? .callout.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let text, let depth):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 12)

        case .code(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(7)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

        case .paragraph(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    // MARK: Feedback

    private var feedbackField: some View {
        TextField(
            "",
            text: $feedback,
            prompt: Text("What should change? (optional)")
                .foregroundStyle(.white.opacity(0.28))
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
                    focused ? (accent ?? .white).opacity(0.55) : .white.opacity(0.08),
                    lineWidth: 1
                )
        )
        .focused($focused)
        // Typing an answer and pressing return should send that answer, which
        // here means "keep planning, and here is why" — not "approve".
        .onSubmit(keepPlanning)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                choice("Auto-accept edits", shortcut: "1", emphasis: 1.0) {
                    coordinator.resolve(prompt, with: .plan(.approve(policy: .acceptEdits)))
                }
                choice("Manual edits", shortcut: "2", emphasis: 0.6) {
                    coordinator.resolve(prompt, with: .plan(.approve(policy: .manual)))
                }
                choice("Keep planning", shortcut: "3", emphasis: 0.35, action: keepPlanning)

                Spacer()

                Button("Later") { coordinator.dismissCurrent() }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel("Dismiss without answering")
            }

            // Says so rather than quietly doing half of what the button reads
            // as. The master switch is the thing that makes auto-accept real.
            if !PolicyStore.masterSwitch {
                Text("Auto-accept needs Auto-answer switched on in the status window — "
                     + "until then button 1 approves the plan and still asks about each edit.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(NotchInk.hint))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func keepPlanning() {
        coordinator.resolve(prompt, with: .plan(.keepPlanning(feedback: feedback)))
    }

    /// Same builder as `PromptCard.choice`, kept in step with it deliberately:
    /// two prompt cards that render their buttons differently would read as two
    /// different apps.
    private func choice(
        _ title: String,
        shortcut: Character?,
        emphasis: Double,
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
        }
        .buttonStyle(.plain)
        .modifier(PlainKeyShortcut(key: shortcut))
        .accessibilityLabel(title)
    }

    /// ⌘L focuses the feedback field, matching every other surface.
    private var focusShortcut: some View {
        Button("") { focused = true }
            .keyboardShortcut("l", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

// MARK: - Markdown, only as far as a plan needs

/// Enough of Markdown to render a plan, and no more.
///
/// A library is the wrong answer here: a plan is headings, bullets, fenced
/// code and paragraphs, the notch is 520pt of white-on-black with a fixed type
/// ladder, and every extra construct a real parser supports is one more thing
/// that can lay out badly in a surface that cannot scroll horizontally.
///
/// Inline emphasis is deliberately left as written — `**bold**` reads fine as
/// literal asterisks, and stripping them would mean a real inline parser.
nonisolated enum PlanMarkdown {

    enum Block: Equatable {
        case heading(String, level: Int)
        case bullet(String, depth: Int)
        case code(String)
        case paragraph(String)
        case rule
    }

    static func blocks(_ markdown: String) -> [Block] {
        var result: [Block] = []
        var fence: [String]?

        for rawLine in markdown.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let open = fence {
                    result.append(.code(open.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence = []
                }
                continue
            }
            if fence != nil {
                fence?.append(rawLine)
                continue
            }

            if trimmed.isEmpty { continue }

            if trimmed.allSatisfy({ $0 == "-" }), trimmed.count >= 3 {
                result.append(.rule)
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix { $0 == "#" }.count
                let text = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    result.append(.heading(text, level: hashes))
                    continue
                }
            }

            if let bullet = bullet(rawLine, trimmed: trimmed) {
                result.append(bullet)
                continue
            }

            result.append(.paragraph(trimmed))
        }

        // An unterminated fence still has to render — a plan cut off mid-block
        // is exactly when you want to see what it said.
        if let open = fence, !open.isEmpty {
            result.append(.code(open.joined(separator: "\n")))
        }
        return result
    }

    private static func bullet(_ rawLine: String, trimmed: String) -> Block? {
        let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count
        let depth = min(indent / 2, 3)

        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return .bullet(String(trimmed.dropFirst(marker.count)), depth: depth)
        }

        // "1. " and friends. Kept as a bullet rather than a numbered list: the
        // number is already in the text, and re-deriving it would renumber a
        // list the model wrote deliberately.
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let rest = trimmed.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .bullet(trimmed, depth: depth)
            }
        }
        return nil
    }
}
