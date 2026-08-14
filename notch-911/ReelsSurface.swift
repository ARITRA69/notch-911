//
//  ReelsSurface.swift
//  notch-911
//
//  Instagram in the notch. A small browser, not an API integration: Meta has no
//  endpoint that returns the feed served *to* you — Basic Display was shut off
//  in December 2024, and every current scope returns only your own posted media
//  — so the only way to scroll reels is a web view with a phone's user agent,
//  logged in by hand.
//
//  Read `ReelsSession` with the security posture in mind. This file signs into a
//  third-party account, so it is written as a set of things it must *not* do:
//  no injected scripts, no message handlers, no `evaluateJavaScript` anywhere
//  (playback is controlled through public WebKit API instead), no auth-challenge
//  delegate, no cookie reads, no page capture, and nothing anywhere that reads a
//  URL beyond its host or a key event beyond its keycode. Each of those is one
//  grep, which is the point: the posture is checkable without reading the logic.
//

import AppKit
import Observation
import WebKit

// MARK: - Scope

/// Where the surface may go on its own. Not a security boundary — WebKit's
/// sandbox is that — but a scope boundary: this is a 380pt window with no
/// address bar and no back button, and a link in a reel caption that quietly
/// turned it into a general-purpose browser would be the worst possible shape
/// for one.
nonisolated enum ReelsPolicy {

    static let start = URL(string: "https://www.instagram.com/reels/")!

    /// Registrable domains. `facebook.com` earns its place by being where
    /// "Log in with Facebook" goes; the CDNs serve the video and the images.
    static let domains: Set<String> = [
        "instagram.com",
        "cdninstagram.com",
        "facebook.com",
        "fbcdn.net",
    ]

    /// Matched label-wise rather than by suffix, so `evil-instagram.com` and
    /// `instagram.com.attacker.net` both fail — a `hasSuffix` on the bare domain
    /// would wave the first one through, and one on the dotted form would wave
    /// through neither but also reject `instagram.com` itself.
    static func isInside(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

// MARK: - Web view

/// Subclassed for exactly three overrides, each of them about a web view living
/// in a borderless, nonactivating panel that is frequently not the key window.
final class ReelsWebView: WKWebView {

    /// The panel loses key whenever the user clicks into their editor. Without
    /// this, the next click on a reel is swallowed re-keying the window and
    /// every interaction costs two clicks.
    ///
    /// Deliberately does not call `super`: WebKit's own implementation asks the
    /// web content process — synchronously, on the click path — whether the
    /// element under the cursor wants first mouse, and answers no over
    /// draggable content, which is most of a feed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// AppKit otherwise defers window ordering in case the mouse-down turns into
    /// a drag, which reads as a click landing a beat late.
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { false }

    /// The context menu is a liability rather than a feature here: "Open Link in
    /// New Window" wants a window this app does not have, "Download Linked File"
    /// wants a download delegate deliberately not implemented, and "Inspect
    /// Element" would open a Web Inspector that takes key from the panel.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

// MARK: - Container

/// Holds the session's web view without owning it. A container rather than
/// handing the web view straight back from `makeNSView`, for two reasons:
///
///  1. `setIdleContent` cross-fades surfaces, so an outgoing and an incoming
///     representable can briefly both exist. Two of them calling `addSubview`
///     on one shared view would have the second steal it and the first's
///     teardown then remove it from the second, leaving a blank surface.
///     Adoption through a container is idempotent and re-entrant.
///  2. It is a view we own, which is somewhere to put `acceptsFirstMouse` for
///     the padding and the hit-test kill switch.
final class ReelsContainerView: NSView {

    override var isFlipped: Bool { true }

    /// Mirrors `.allowsHitTesting(isExpanded)` in AppKit terms. That modifier
    /// *should* reach a hosted `NSView`, but the failure mode if it does not is
    /// silent and bad — scrolling anywhere in the panel's 720×620 footprint
    /// while it is collapsed would scroll an invisible Instagram feed instead of
    /// the user's document. Same trick as `PointerTracker`.
    var isInert = true

    private var hasClaimedFocus = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInert ? nil : super.hitTest(point)
    }

    /// Covers the padding around the web view; the web view answers for itself.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func adopt(_ webView: WKWebView) {
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// `setVisible` makes the panel key, but AppKit then picks its own first
    /// responder — which is the `NSHostingView`, not the web view. Without this
    /// the login form silently swallows every keystroke until the user thinks to
    /// click into it.
    ///
    /// Claimed once per presentation rather than on every `updateNSView`:
    /// re-claiming would yank focus back out of whatever the page moved it to.
    func claimFocusIfNeeded(for webView: NSView) {
        guard !isInert, !hasClaimedFocus, let window, window.isKeyWindow else { return }
        hasClaimedFocus = true
        window.makeFirstResponder(webView)
    }

    func releaseFocusClaim() { hasClaimedFocus = false }
}

// MARK: - Session

/// Owns the one web view for as long as the app runs. Deliberately not built by
/// the representable: idle content is unmounted 800ms after the notch collapses,
/// so a view created in `makeNSView` would be destroyed and rebuilt on every
/// open — reloading the page, losing the scroll position, losing a half-typed
/// login. The cookies would survive, since they live in the data store, but
/// nothing else would.
@MainActor
@Observable
final class ReelsSession {

    static let enabledDefaultsKey = "notchd.reels"

    /// Height is the binding side — the panel is a fixed 620pt and never
    /// resized — so this is spent against a budget rather than chosen. Counting
    /// down from the top: notch inset + 8 (46), heading (14), spacing (8), this,
    /// spacing (8), footer (13), bottom padding (16), then the shadow's offset
    /// and clamped radius (50 at this height). 448 leaves 17pt for a Mac
    /// reporting a fatter `safeAreaInsets.top` than the 38 assumed here.
    ///
    /// `ClipboardCard` spends the same budget more cautiously at 420. It can
    /// afford to: a list that is one row shorter still reads as a list, whereas
    /// a reel is the only thing on this surface worth looking at.
    static let webHeight: CGFloat = 448
    /// Reels are 9:16, so the frame is too — the video fills it edge to edge
    /// instead of sitting in ~70pt of letterbox on either side.
    static let webWidth: CGFloat = (webHeight * 9 / 16).rounded()

    /// What Instagram's layout is drawn against. The frame is narrower than this
    /// now, and at 236 CSS px their mobile breakpoints start folding — so the
    /// page is rendered at phone width and scaled down to fit, rather than
    /// handed a viewport it has no layout for.
    private static let layoutWidth: CGFloat = 320

    @ObservationIgnored let webView: ReelsWebView

    /// Host only, for the heading. A borderless panel has no address bar, so
    /// this is the user's only way to tell whether they are typing a password
    /// into instagram.com or into somewhere a caption link took them.
    ///
    /// Host — never the path, the query or the fragment. An OAuth redirect
    /// carries `code=` in exactly those, and this app has a user-visible event
    /// log one careless `append(...)` away.
    private(set) var host: String?
    private(set) var failure: String?
    private(set) var isLive = false

    /// Raised for `esc`. Owned by whoever builds the session, so this file never
    /// reaches into the coordinator.
    @ObservationIgnored var onEscape: (() -> Void)?

    @ObservationIgnored private let navigator = ReelsNavigator()
    @ObservationIgnored private var hostObservation: NSKeyValueObservation?
    @ObservationIgnored private var escMonitor: Any?
    @ObservationIgnored private var hasLoaded = false

    init() {
        webView = ReelsWebView(frame: .zero, configuration: Self.makeConfiguration())
        Self.configure(webView)
        navigator.session = self
        webView.navigationDelegate = navigator
        webView.uiDelegate = navigator

        // KVO rather than a `didCommit` delegate callback: Instagram is a single
        // page app and pushes history without committing a navigation, so the
        // delegate would leave a stale host on screen. Reduced to `.host` on the
        // way in; nothing else about the URL is ever read.
        hostObservation = webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
            let host = view.url?.host
            MainActor.assumeIsolated { self?.host = host }
        }
    }

    deinit { hostObservation?.invalidate() }

    // MARK: Lifetime

    /// The single funnel for "are the reels actually on screen", driven from
    /// `NotchPromptView.sync()` on the leading edge of every change. Idempotent,
    /// because a preemption runs `sync()` twice.
    ///
    /// This is a correctness requirement, not a nicety: audio is on by default,
    /// and a `WKWebView` removed from the view hierarchy is only detached — it
    /// keeps playing into a room where the surface it came from is gone.
    func setLive(_ live: Bool) {
        guard live != isLive else { return }
        isLive = live
        if live {
            loadIfNeeded()
            webView.setAllMediaPlaybackSuspended(false, completionHandler: nil)
            installEscapeMonitor()
        } else {
            // Kills any picture-in-picture window first; it would otherwise
            // outlive the surface and float over the screen with no owner.
            webView.closeAllMediaPresentations(completionHandler: nil)
            webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            removeEscapeMonitor()
        }
    }

    func reload() {
        failure = nil
        if hasLoaded { webView.reload() } else { loadIfNeeded() }
    }

    func goToStart() {
        failure = nil
        hasLoaded = true
        webView.load(URLRequest(url: ReelsPolicy.start))
    }

    /// Clears the stored Instagram session. Lives here so `WebKit` stays in this
    /// file and `AppModel` does not have to import it.
    static func signOut() async {
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }

    fileprivate func report(_ message: String) { failure = message }

    fileprivate func clearFailure() { failure = nil }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        webView.load(URLRequest(url: ReelsPolicy.start))
    }

    // MARK: Escape

    /// `esc` cannot go through `.keyboardShortcut` the way the clipboard and the
    /// game do it. Those are key *equivalents*, dispatched from the hosting view
    /// before `keyDown:` reaches the first responder — so with a login field
    /// focused, `esc` would collapse the notch and the page would never see the
    /// key at all. WebKit's unhandled-key resend runs `performKeyEquivalent` a
    /// second time, so a shortcut cannot be made to yield to the page either.
    ///
    /// A local monitor runs inside `NSApplication.sendEvent:`, ahead of the
    /// window's key-equivalent pass, which puts the ordering back in our hands.
    /// It needs no Accessibility permission — unlike a *global* monitor, and for
    /// the same reason `GlobalHotkey` went to Carbon instead.
    ///
    /// The page never gets `esc`. Letting it have the first press and closing on
    /// the second would mean knowing whether an editable element has focus, and
    /// the only way to know that is to inject a script watching the login form —
    /// which the posture at the top of this file forbids. The cost is near zero:
    /// closing does not unload the page, so a half-typed username is still there
    /// when you reopen.
    private func installEscapeMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // First line, and it stays the first line. This closure sees every
            // keystroke typed into this process while the surface is up,
            // including the user's Instagram password. It branches on the raw
            // keycode and never touches `characters`, never touches
            // `charactersIgnoringModifiers`, and never logs.
            guard event.keyCode == 53 else { return event }
            guard let self, event.window === self.webView.window else { return event }
            self.onEscape?()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        escMonitor.map(NSEvent.removeMonitor)
        escMonitor = nil
    }

    // MARK: Configuration

    /// A real, shipped iOS Safari string. Instagram serves its mobile web app on
    /// a user-agent sniff, and the desktop site in a 380pt column is unusable.
    ///
    /// It is load-bearing twice over: mobile browsers block popups, so Facebook
    /// serves the *redirect* OAuth flow to this UA rather than the desktop popup
    /// flow that depends on `window.opener` — and a popup is a second window,
    /// which would take key from the panel.
    ///
    /// Deliberately not a made-up newer version: the WebKit actually running
    /// here is the host system's, and claiming a Safari ahead of it makes
    /// feature detection lie in the wrong direction. Revisit when Instagram
    /// starts drawing an "unsupported browser" notice; that is the only signal.
    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    private static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()

        // Persistent, so the user logs in once. `.nonPersistent()` would mean
        // logging into Instagram on every launch, which is the whole feature.
        // Note it does not share cookies with Safari.
        configuration.websiteDataStore = .default()

        // Sound on: the surface is a feed, and a muted feed is a different
        // thing. The silence guarantee comes from `setLive(false)` instead,
        // which is why that runs on the leading edge of every exit.
        configuration.mediaTypesRequiringUserActionForPlayback = []

        configuration.upgradeKnownHostsToHTTPS = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        // Element fullscreen creates a real fullscreen window: it takes key from
        // the panel, and a notch surface going fullscreen is nonsense anyway.
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        // `configuration.userContentController` is deliberately left untouched.
        // No user scripts, no message handlers, now or later.
        return configuration
    }

    private static func configure(_ webView: ReelsWebView) {
        webView.customUserAgent = mobileUserAgent

        // Not set: `applicationNameForUserAgent`. It only appends to the default
        // agent and is ignored once `customUserAgent` exists, so setting both
        // reads as a bug — and it would broadcast "notch-911" to Instagram on
        // every request, tying the user's account to this app.

        // A two-finger horizontal swipe is how Instagram pages a carousel. With
        // this on, it is also how you navigate back.
        webView.allowsBackForwardNavigationGestures = false
        // Renders a `layoutWidth` viewport into the narrower 9:16 frame. The
        // video scales with it and still fills the frame, because the frame and
        // the reel are the same shape.
        webView.pageZoom = webWidth / layoutWidth
        // Pinch-zoom inside a column this narrow produces a view nobody can undo.
        webView.allowsMagnification = false
        // Force-touch link preview opens a popover — another loose surface
        // floating over the menu bar.
        webView.allowsLinkPreview = false
        // Explicit, and a security control rather than a debug convenience: an
        // inspectable web view lets Safari's Develop menu attach to the live DOM,
        // including the value of the password field.
        webView.isInspectable = false
        // The panel is transparent over a black notch shape, so an unstyled web
        // view flashes white on every load.
        webView.underPageBackgroundColor = .black
    }
}

// MARK: - Delegates

/// Split out so `ReelsSession` need not be an `NSObject`. Holds the session
/// weakly — the session owns the web view, which owns these delegate slots.
private final class ReelsNavigator: NSObject, WKNavigationDelegate, WKUIDelegate {

    weak var session: ReelsSession?

    /// Reads `host` and nothing else — not the path, not the query, not the
    /// fragment. See the note on `ReelsSession.host`.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Cancelled rather than handed to `NSWorkspace.open`: opening a URL that
        // came from page content is its own link-safety question, and a panel
        // with no address bar is not the place to adjudicate it.
        decisionHandler(ReelsPolicy.isInside(url) ? .allow : .cancel)
    }

    /// "Log in with Facebook" is a `window.open`. Returning nil on its own would
    /// make the button dead; building a real second web view would mean a second
    /// window, which takes key from the panel and trips `windowDidResignKey`. So
    /// the popup is flattened into the same view.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           ReelsPolicy.isInside(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// The app ships no `NSCameraUsageDescription` — `GENERATE_INFOPLIST_FILE`
    /// is on and the only key set is the copyright — so letting WebKit reach the
    /// TCC prompt is a crash rather than a denial. Reels needs neither camera
    /// nor microphone.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }

    // Deliberately not implemented: `runJavaScriptAlertPanel` and friends (WebKit
    // handles the unimplemented case, and an `NSAlert` from a background app
    // steals key), `runOpenPanel` (an `NSOpenPanel` is another key-stealing
    // window, and nothing here uploads), and `didReceive challenge:` — that last
    // one is the single delegate that would put credentials in this process.

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { session?.report(error.localizedDescription) }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated { session?.report(error.localizedDescription) }
    }

    /// A navigation that got as far as committing means whatever failed last
    /// time no longer describes what is on screen.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated { session?.clearFailure() }
    }
}
