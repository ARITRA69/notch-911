//
//  ReelsCard.swift
//  notch-911
//
//  The chrome around `ReelsSession`'s web view. Mirrors `SnakeSurface` — heading
//  with a back chevron, body, footer — with one deliberate difference: there is
//  no `.keyboardShortcut(.escape)` button here, and no bare arrow, return or
//  delete bindings either. Those are key *equivalents*, dispatched before
//  `keyDown:` reaches the first responder, so each one would quietly steal a key
//  the login form or the feed needs. `esc` is handled by the session's scoped
//  event monitor instead; see the note on `installEscapeMonitor`.
//

import SwiftUI
import WebKit

struct ReelsCard: View {
    let coordinator: PromptCoordinator
    let session: ReelsSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            surface(for: session.failure)
                .frame(width: ReelsSession.webWidth, height: ReelsSession.webHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            footer
        }
    }

    @ViewBuilder
    private func surface(for failure: String?) -> some View {
        if let failure {
            // Rendered in place of the web view so a load error is a sentence
            // rather than a black rectangle nobody can diagnose.
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.35))
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reload") { session.reload() }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.35))
        } else {
            ReelsWebHost(session: session)
        }
    }

    private var heading: some View {
        HStack(spacing: 4) {
            Button { coordinator.back() } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to the notch overview")
            BrandMark("Logos/logo.instagram", size: 11)
            Text("Reels")
            Spacer(minLength: 0)
            // The only indication of where the surface actually is. A borderless
            // panel has no address bar, so without this there is nothing to tell
            // the user whether they are typing a password into instagram.com.
            if let host = session.host {
                Text(host)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .accessibilityLabel("Showing \(host)")
            }
            Button { session.goToStart() } label: {
                Image(systemName: "house")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to reels")
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.35))
    }

    /// ⌘V is spelled out because it is the only way in. `WKWebView` has no
    /// password-manager autofill — that lives in Safari, not in WebKit — and
    /// passkeys need an entitlement this app does not carry.
    private var footer: some View {
        Text("scroll to browse · ⌘V to paste · ⎋ close")
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.25))
    }
}

// MARK: - Host

/// Borrows the session's web view; never owns it. The session outlives every
/// mount, which is what lets the login, the scroll position and the buffered
/// video survive the notch collapsing.
private struct ReelsWebHost: NSViewRepresentable {
    let session: ReelsSession

    func makeNSView(context: Context) -> ReelsContainerView {
        let container = ReelsContainerView()
        container.adopt(session.webView)
        return container
    }

    func updateNSView(_ container: ReelsContainerView, context: Context) {
        // Re-adopting is cheap and idempotent, and it repairs the case where a
        // cross-fade briefly reparented the view to an outgoing card.
        container.adopt(session.webView)
        container.isInert = !session.isLive
        if session.isLive {
            container.claimFocusIfNeeded(for: session.webView)
        } else {
            container.releaseFocusClaim()
        }
    }

    /// Detaches without tearing down. Nothing here stops loading, clears a
    /// delegate or releases the web view — that all belongs to the session.
    static func dismantleNSView(_ container: ReelsContainerView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}
