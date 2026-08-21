//
//  CompletionCard.swift
//  notch-911
//
//  "The agent finished." The only notch surface with nothing to answer.
//
//  There are no controls on it — a button on a surface that vanishes after
//  four seconds is a button the user will miss and then hunt for. The whole
//  card is the target instead: click anywhere and the agent that just finished
//  comes forward.
//

import AppKit
import SwiftUI

struct CompletionCard: View {
    let notice: CompletionNotice
    let coordinator: PromptCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            headline
            if !notice.summary.isEmpty {
                Text(notice.summary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    // Two lines is the ceiling the trim in `CompletionNotice`
                    // is sized against; a third would start moving the panel's
                    // height around between one completion and the next.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The whole card, not a button inside it: the target should be as big
        // as the thing you are looking at.
        .contentShape(Rectangle())
        .onTapGesture(perform: openAgent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens \(notice.agent.displayName)")
        .accessibilityAddTraits(.isButton)
    }

    /// Brings the agent's desktop client forward, then takes the banner away.
    ///
    /// Dismissing first would be wrong — the click has to survive long enough
    /// to activate something — but leaving the banner up behind the app that
    /// just came forward would park it over the window the user asked to see.
    private func openAgent() {
        let bundleID = notice.agent.desktopBundleID
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).first {
            running.activate(options: [.activateAllWindows])
        } else if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        coordinator.dismissCompletion()
    }

    /// Matches the prompt card's header so the two read as the same family:
    /// mark, project, agent — then the one thing this surface knows and that
    /// one doesn't, which is how long the turn took.
    private var header: some View {
        HStack(spacing: 6) {
            BrandMark(notice.agent.logoAsset, size: 12)
                .foregroundStyle(.white.opacity(0.85))
                .opacity(0.85)
            Text(notice.projectName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            Text(notice.agent.displayName)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)

            Spacer(minLength: 8)

            if let durationText = notice.durationText {
                Text(durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private var headline: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(0.14)))
            Text("Task complete")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
        .accessibilityHidden(true)
    }

    private var accessibilityText: String {
        var parts = ["\(notice.agent.displayName) finished in \(notice.projectName)"]
        if let durationText = notice.durationText { parts.append("after \(durationText)") }
        if !notice.summary.isEmpty { parts.append(notice.summary) }
        return parts.joined(separator: ", ")
    }
}
