import Foundation
import Testing
@testable import notch_911

@Suite("Home tab")
@MainActor
struct HomeTabTests {

    // MARK: Where a click lands

    /// The point of the change. `allCases` order is both the tab-bar order and
    /// the order `[` and `]` walk, so this pins the layout as well as the
    /// landing tab.
    @Test("Home is the first tab")
    func homeIsFirst() {
        #expect(NotchTab.allCases.first == .home)
        #expect(NotchTab.allCases == [.home, .agents, .media, .tools])
    }

    @Test("A fresh coordinator starts on Home")
    func startsOnHome() {
        #expect(PromptCoordinator().selectedTab == .home)
    }

    @Test("Every tab has a title and a glyph", arguments: NotchTab.allCases)
    func tabsAreLabelled(_ tab: NotchTab) {
        #expect(!tab.title.isEmpty)
        #expect(!tab.symbol.isEmpty)
    }

    // MARK: What the disk scan is gated on

    /// The idle-cost promise lives here. A scan that quietly ran on Media or
    /// Tools would list transcripts because someone looked at a track, and
    /// nothing else in the suite would notice.
    @Test("Only Home and Agents keep the session scan running",
          arguments: NotchTab.allCases)
    func scanIsGatedToSessionTabs(_ tab: NotchTab) {
        let coordinator = PromptCoordinator()
        coordinator.openTabs()
        coordinator.selectTab(tab)

        let shouldScan = (tab == .home || tab == .agents)
        #expect(coordinator.isSessionListLive == shouldScan)
    }

    @Test("Nothing scans while the tabs are closed")
    func noScanWhenClosed() {
        let coordinator = PromptCoordinator()
        coordinator.selectTab(.home)
        #expect(coordinator.idleSurface == .none)
        #expect(coordinator.isSessionListLive == false)
    }

    /// A prompt takes the notch, so the tab underneath is not on screen and has
    /// no business polling the disk.
    @Test("A blocked prompt stops the scan")
    func promptStopsTheScan() async {
        let coordinator = PromptCoordinator()
        coordinator.openTabs()
        coordinator.selectTab(.home)
        #expect(coordinator.isSessionListLive)

        let prompt = Prompt(
            agent: .claudeCode,
            event: .permissionRequest,
            sessionId: "s",
            cwd: "/tmp/p",
            title: "Bash",
            summary: "",
            kind: .permission,
            receivedAt: Date()
        )
        let task = Task { await coordinator.response(to: prompt) }
        while coordinator.current?.id != prompt.id { await Task.yield() }

        #expect(coordinator.isSessionListLive == false)

        coordinator.resolve(prompt, with: .permission(.allow))
        _ = await task.value
    }

    // MARK: Getting back to it

    /// The tabs survive being preempted, so answering a prompt should return to
    /// the tab you were on rather than collapsing — and Home is now that tab by
    /// default.
    @Test("Answering a prompt hands the tabs back on the same tab")
    func tabsComeBackOnTheSameTab() async {
        let coordinator = PromptCoordinator()
        coordinator.openTabs()
        coordinator.selectTab(.agents)

        let prompt = Prompt(
            agent: .claudeCode,
            event: .permissionRequest,
            sessionId: "s",
            cwd: "/tmp/p",
            title: "Bash",
            summary: "",
            kind: .permission,
            receivedAt: Date()
        )
        let task = Task { await coordinator.response(to: prompt) }
        while coordinator.current?.id != prompt.id { await Task.yield() }
        #expect(coordinator.idleSurface == .none)

        coordinator.resolve(prompt, with: .permission(.allow))
        _ = await task.value

        #expect(coordinator.idleSurface == .tabs)
        // The selection outlives the teardown — that is why it lives on the
        // coordinator rather than in the card's own view state.
        #expect(coordinator.selectedTab == .agents)
    }
}
