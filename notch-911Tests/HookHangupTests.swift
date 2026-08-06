import Foundation
import Network
import Testing
@testable import notch_911

@Suite("Hook client hangup")
struct HookHangupTests {

    @Test("A normal request still gets its response")
    func normalRoundTrip() async throws {
        let server = HookServer(token: "secret") { _ in
            HookServer.Response(status: 200, body: Data(#"{"ok":true}"#.utf8))
        }
        let port = try await server.start()
        defer { server.stop() }

        let reply = try await send(request(token: "secret"), to: port, thenReadReply: true)
        #expect(reply.contains("200 OK"))
        #expect(reply.contains(#"{"ok":true}"#))
    }

    @Test("Closing the connection mid-decision cancels the handler")
    func hangupCancelsHandler() async throws {
        let cancelled = AsyncStream.makeStream(of: Bool.self)
        let server = HookServer(token: "secret") { _ in
            // Parks like a real blocked prompt; only cancellation ends it early.
            do {
                try await Task.sleep(for: .seconds(30))
                cancelled.continuation.yield(false)
            } catch {
                cancelled.continuation.yield(true)
            }
            return .noDecision
        }
        let port = try await server.start()
        defer { server.stop() }

        _ = try await send(request(token: "secret"), to: port, thenReadReply: false)

        var iterator = cancelled.stream.makeAsyncIterator()
        let sawCancellation = await iterator.next()
        #expect(sawCancellation == true)
    }

    @Test("Cancelling the awaiting task retracts the card and frees the queue")
    @MainActor
    func cancellationRetractsPrompt() async throws {
        let coordinator = PromptCoordinator()
        let prompt = Prompt(
            agent: .claudeCode,
            event: .permissionRequest,
            sessionId: "s",
            cwd: "/tmp/p",
            title: "AskUserQuestion",
            summary: "",
            kind: .permission,
            receivedAt: Date()
        )

        let task = Task { await coordinator.response(to: prompt) }
        // Let the response call register and present before cancelling.
        while coordinator.current == nil { await Task.yield() }
        #expect(coordinator.current?.id == prompt.id)

        task.cancel()
        let response = await task.value
        #expect(response == nil)
        #expect(coordinator.current == nil)
        #expect(coordinator.stranded.isEmpty)
    }

    @Test("A resolved prompt is not disturbed by a late hangup")
    @MainActor
    func lateHangupIsNoOp() async throws {
        let coordinator = PromptCoordinator()
        let first = Prompt(
            agent: .claudeCode, event: .permissionRequest, sessionId: "s", cwd: "/tmp/p",
            title: "Bash", summary: "ls", kind: .permission, receivedAt: Date()
        )
        let second = Prompt(
            agent: .claudeCode, event: .permissionRequest, sessionId: "s", cwd: "/tmp/p",
            title: "Write", summary: "file", kind: .permission, receivedAt: Date()
        )

        let firstTask = Task { await coordinator.response(to: first) }
        while coordinator.current == nil { await Task.yield() }
        let secondTask = Task { await coordinator.response(to: second) }
        while coordinator.waitingCount == 0 { await Task.yield() }

        // The user answers first; the queue advances to second.
        coordinator.resolve(first, with: .permission(.allow))
        let firstResponse = await firstTask.value
        if case .permission(.allow) = try #require(firstResponse) {} else {
            Issue.record("expected allow, got \(String(describing: firstResponse))")
        }
        #expect(coordinator.current?.id == second.id)

        // A hangup for the already-resolved first prompt must not touch second.
        firstTask.cancel()
        await Task.yield()
        #expect(coordinator.current?.id == second.id)

        coordinator.resolve(second, with: .permission(.deny))
        _ = await secondTask.value
    }

    // MARK: Raw socket plumbing

    private func request(token: String) -> Data {
        let text = "POST /notchd/permission HTTP/1.1\r\n"
            + "Authorization: Bearer \(token)\r\n"
            + "Content-Length: 2\r\n\r\n{}"
        return Data(text.utf8)
    }

    /// Sends raw bytes, then either reads until the server closes (the reply)
    /// or closes immediately to simulate the client hanging up.
    private func send(_ payload: Data, to port: UInt16, thenReadReply: Bool) async throws -> String {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let queue = DispatchQueue(label: "hangup-test-client")
        connection.start(queue: queue)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }

        guard thenReadReply else {
            // Give the server a beat to parse and park the handler, then slam
            // the connection shut like an interrupted agent would.
            try await Task.sleep(for: .milliseconds(300))
            connection.forceCancel()
            return ""
        }

        var received = Data()
        while true {
            let (chunk, isComplete): (Data?, Bool) = await withCheckedContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
                    data, _, complete, error in
                    c.resume(returning: (error == nil ? data : nil, complete || error != nil))
                }
            }
            if let chunk { received.append(chunk) }
            if isComplete { break }
        }
        connection.cancel()
        return String(decoding: received, as: UTF8.self)
    }
}
