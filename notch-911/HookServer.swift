//
//  HookServer.swift
//  notch-911
//
//  Loopback-only HTTP/1.1 server. Claude Code POSTs a hook event here and blocks
//  on the response body; we hold the connection open until the user decides.
//
//  Deliberately hand-rolled over Network.framework rather than pulling in NIO or
//  Vapor — this handles a handful of requests a minute from a single client on
//  localhost, with `Connection: close` on every response so there is no
//  keep-alive state to track.
//

import Foundation
import Network
import os

nonisolated final class HookServer: @unchecked Sendable {

    // MARK: Types

    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct Response: Sendable {
        var status: Int = 200
        var body: Data = Data()

        /// Fail-open response. §11: a 2xx with an empty body reads to Claude Code
        /// as "no decision", so it falls through to its own permission prompt.
        static let noDecision = Response()
    }

    enum StartError: Error, LocalizedError {
        case couldNotBind(Error)

        var errorDescription: String? {
            switch self {
            case .couldNotBind(let underlying):
                return "Could not bind a loopback port: \(underlying.localizedDescription)"
            }
        }
    }

    // MARK: State

    /// Ports tried in order before falling back to a kernel-assigned one.
    private static let preferredPorts: [UInt16] = Array(8917...8926)

    private let queue = DispatchQueue(label: "com.aritra360.notch-911.hookserver")
    private let log = Logger(subsystem: "com.aritra360.notch-911", category: "HookServer")
    private let token: String
    private let handler: @Sendable (Request) async -> Response

    /// Guarded by `queue`.
    private var listener: NWListener?

    init(token: String, handler: @escaping @Sendable (Request) async -> Response) {
        self.token = token
        self.handler = handler
    }

    // MARK: Lifecycle

    /// Binds 127.0.0.1 and returns the port actually in use.
    ///
    /// Tries the preferred range first so the port stays stable across launches
    /// during development, then falls back to port 0 (kernel-assigned) so a
    /// crowded machine can never stop the app from starting.
    func start() async throws -> UInt16 {
        var lastError: Error?
        for candidate in Self.preferredPorts + [0] {
            do {
                return try await bind(port: candidate)
            } catch {
                lastError = error
                log.error("port \(candidate) unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        throw StartError.couldNotBind(lastError ?? POSIXError(.EADDRINUSE))
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func bind(port rawPort: UInt16) async throws -> UInt16 {
        let port = NWEndpoint.Port(rawValue: rawPort) ?? .any
        let parameters = NWParameters.tcp
        // Loopback only. §5.4 — never 0.0.0.0, not even briefly.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true

        // The port lives in `requiredLocalEndpoint` and nowhere else. Passing it
        // again via `NWListener(using:on:)` makes the two specifications collide
        // and the initialiser throws EINVAL for every concrete port — which
        // silently degrades into "always ephemeral", since only `.any` survives.
        let listener = try NWListener(using: parameters)

        return try await withCheckedThrowingContinuation { continuation in
            // NWListener can report .ready and .failed more than once over its
            // lifetime; the continuation may only be resumed once.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Result<UInt16, Error>) -> Void = { result in
                let alreadyResumed = resumed.withLock { flag -> Bool in
                    defer { flag = true }
                    return flag
                }
                guard !alreadyResumed else { return }
                continuation.resume(with: result)
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let bound = listener.port?.rawValue ?? rawPort
                    self.log.info("listening on 127.0.0.1:\(bound)")
                    finish(.success(bound))
                case .failed(let error), .waiting(let error):
                    // .waiting on a loopback listener means the address is taken;
                    // it will never resolve itself, so treat it as a failure.
                    listener.cancel()
                    finish(.failure(error))
                case .cancelled:
                    finish(.failure(StartError.couldNotBind(POSIXError(.ECANCELED))))
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            self.queue.async {
                self.listener?.cancel()
                self.listener = listener
            }
            listener.start(queue: self.queue)
        }
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            if let error {
                self.log.error("receive failed: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            switch Self.parse(buffer) {
            case .complete(let request):
                self.dispatch(request, on: connection)
            case .invalid:
                self.send(Response(status: 400), on: connection)
            case .incomplete:
                if isComplete {
                    connection.cancel()   // client hung up mid-request
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func dispatch(_ request: Request, on connection: NWConnection) {
        guard authorised(request) else {
            log.error("rejected unauthenticated request to \(request.path)")
            send(Response(status: 401), on: connection)
            return
        }
        let task = Task { [handler] in
            let response = await handler(request)
            // A cancelled handler means the client already hung up — sending
            // would only error against a dead socket.
            guard !Task.isCancelled else { return }
            self.send(response, on: connection)
        }
        watchForHangup(on: connection, cancelling: task)
    }

    /// The handler can block for minutes while the user decides, and in that
    /// window the client may abandon the call — the question got answered in
    /// the session, or the turn was interrupted. An HTTP/1.1 client sends
    /// nothing after its request, so the only thing this receive can ever
    /// deliver is the hangup; when it comes, cancel the handler so the UI can
    /// retract a card whose question no longer exists.
    private func watchForHangup(on connection: NWConnection, cancelling task: Task<Void, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 12) {
            [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                // Also fires when *we* close after responding; cancelling a
                // finished task is a no-op, so no state is needed to tell the
                // two apart.
                task.cancel()
                connection.cancel()
            } else {
                // Stray bytes from a nonconforming client. Keep watching.
                self?.watchForHangup(on: connection, cancelling: task)
            }
        }
    }

    private func authorised(_ request: Request) -> Bool {
        guard let header = request.headers["authorization"] else { return false }
        let expected = "Bearer \(token)"
        // Length-independent comparison is overkill for a loopback socket, but
        // the token is the only thing standing between a local process and an
        // approve-anything endpoint.
        guard header.utf8.count == expected.utf8.count else { return false }
        return zip(header.utf8, expected.utf8).reduce(into: UInt8(0)) { $0 |= $1.0 ^ $1.1 } == 0
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reasonPhrase(response.status))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { [log] error in
            if let error {
                log.error("send failed: \(error.localizedDescription)")
            }
            connection.cancel()
        })
    }

    // MARK: Parsing

    private enum ParseResult {
        case incomplete
        case invalid
        case complete(Request)
    }

    private static func parse(_ data: Data) -> ParseResult {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let headerText = String(data: data[data.startIndex..<separator.lowerBound], encoding: .utf8)
        else { return .invalid }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        guard data.endIndex - bodyStart >= contentLength else { return .incomplete }

        return .complete(
            Request(
                method: String(requestLine[0]),
                path: String(requestLine[1]),
                headers: headers,
                body: Data(data[bodyStart..<(bodyStart + contentLength)])
            )
        )
    }

    private static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        default: return "Status"
        }
    }
}
