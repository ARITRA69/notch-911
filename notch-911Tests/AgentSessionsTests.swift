import Foundation
import Testing
@testable import notch_911

@Suite("Agent session parsing")
struct AgentSessionsTests {

    // MARK: Claude Code transcripts

    @Test("Reads cwd, branch, mode and timestamp out of a transcript tail")
    func parsesClaudeTail() throws {
        let text = """
        {"type":"user","sessionId":"abc","cwd":"/Users/me/Code/thing","gitBranch":"main","timestamp":"2026-08-21T10:00:00.000Z"}
        {"type":"assistant","sessionId":"abc","cwd":"/Users/me/Code/thing","timestamp":"2026-08-21T10:00:05.500Z"}
        """
        let session = try #require(
            AgentSessionScan.parseClaudeTail(text, sessionID: "abc")
        )

        #expect(session.id == "abc")
        #expect(session.agent == .claudeCode)
        #expect(session.cwd == "/Users/me/Code/thing")
        #expect(session.projectName == "thing")
        // The newest record wins for the timestamp, and that record carries no
        // branch — so the walk has to keep going for the fields it hasn't
        // answered yet rather than stopping at the first line it can read.
        #expect(session.gitBranch == "main")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(session.lastActivity == formatter.date(from: "2026-08-21T10:00:05.500Z"))
    }

    @Test("The newest permissionMode is the one reported")
    func newestModeWins() throws {
        let text = """
        {"type":"user","cwd":"/p","permissionMode":"plan","timestamp":"2026-08-21T10:00:00.000Z"}
        {"type":"user","cwd":"/p","permissionMode":"acceptEdits","timestamp":"2026-08-21T10:05:00.000Z"}
        """
        let session = try #require(AgentSessionScan.parseClaudeTail(text, sessionID: "s"))
        #expect(session.observedMode == "acceptEdits")
    }

    /// The case a real tail read hits nearly every time: the window starts in
    /// the middle of a record, so the first line is half a JSON object.
    @Test("A tail that begins mid-record drops the partial first line")
    func truncatedFirstLine() throws {
        let text = """
        put":{"file_path":"/x"}},"timestamp":"2026-08-21T09:00:00.000Z"}
        {"type":"user","cwd":"/Users/me/real","gitBranch":"feature","timestamp":"2026-08-21T10:00:00.000Z"}
        """
        let session = try #require(AgentSessionScan.parseClaudeTail(text, sessionID: "s"))
        #expect(session.cwd == "/Users/me/real")
        #expect(session.gitBranch == "feature")
    }

    /// The other end of the same problem: a transcript being written to while
    /// we read it leaves the *last* line half-finished.
    @Test("A truncated last line is skipped, not misread")
    func truncatedLastLine() throws {
        let text = """
        {"type":"user","cwd":"/Users/me/good","timestamp":"2026-08-21T10:00:00.000Z"}
        {"type":"assistant","cwd":"/Users/me/tru
        """
        let session = try #require(AgentSessionScan.parseClaudeTail(text, sessionID: "s"))
        #expect(session.cwd == "/Users/me/good")
    }

    @Test("A tail with no usable cwd yields no session")
    func noCwdMeansNoSession() {
        #expect(AgentSessionScan.parseClaudeTail("", sessionID: "s") == nil)
        #expect(AgentSessionScan.parseClaudeTail("not json at all", sessionID: "s") == nil)
        #expect(AgentSessionScan.parseClaudeTail(
            #"{"type":"user","timestamp":"2026-08-21T10:00:00.000Z"}"#,
            sessionID: "s"
        ) == nil)
    }

    /// Every field but `cwd` is optional, because the format is undocumented
    /// and can change without notice.
    @Test("Missing branch, mode and timestamp still produce a listable session")
    func degradesToWhatIsKnown() throws {
        let text = #"{"type":"user","cwd":"/Users/me/bare"}"#
        let session = try #require(AgentSessionScan.parseClaudeTail(text, sessionID: "s"))
        #expect(session.projectName == "bare")
        #expect(session.gitBranch == nil)
        #expect(session.observedMode == nil)
        #expect(session.lastActivity == .distantPast)
    }

    // MARK: Codex rollouts

    @Test("Reads a Codex rollout's session_meta header")
    func parsesCodexHead() throws {
        let modified = Date(timeIntervalSince1970: 1_770_000_000)
        let text = """
        {"timestamp":"2026-08-07T15:23:27.017Z","type":"session_meta","payload":{"session_id":"019f","cwd":"/Users/me/work/api"}}
        {"type":"response_item","payload":{}}
        """
        let session = try #require(AgentSessionScan.parseCodexHead(text, modifiedAt: modified))

        #expect(session.id == "019f")
        #expect(session.agent == .codex)
        #expect(session.projectName == "api")
        // Codex writes its identity once at the head, so the file's own mtime is
        // the only honest answer for "when did this last do something".
        #expect(session.lastActivity == modified)
    }

    @Test("A rollout with no session_meta yields no session")
    func codexWithoutMeta() {
        let text = #"{"type":"response_item","payload":{}}"#
        #expect(AgentSessionScan.parseCodexHead(text, modifiedAt: Date()) == nil)
    }

    // MARK: Ordering

    /// What the Agents tab is sorted by. Anything blocked on you comes first,
    /// whatever its timestamp says.
    @Test("Waiting outranks running, which outranks idle")
    func rankOrdering() {
        func session(_ state: AgentSession.State) -> AgentSession {
            var made = AgentSession(
                id: UUID().uuidString,
                agent: .claudeCode,
                cwd: "/p",
                gitBranch: nil,
                observedMode: nil,
                lastActivity: Date()
            )
            made.state = state
            return made
        }
        #expect(session(.waiting).rank < session(.running).rank)
        #expect(session(.running).rank < session(.idle).rank)
    }
}
