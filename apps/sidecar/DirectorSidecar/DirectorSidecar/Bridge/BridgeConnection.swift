//
//  BridgeConnection.swift
//  DirectorSidecar
//
//  G1 (T-G1.2): the ONE shared persistent streaming client for the engine bridge — replaces
//  the G0 request/response BridgeClient (fresh socket per call). A single `URLSessionWebSocketTask`
//  held open, a receive loop routing frames by topic to the store, exponential-backoff reconnect
//  (250ms → 5s), and latest-wins re-prime on (re)connect. Decode happens off the main actor; the
//  store mutation hops to @MainActor via the handler.
//
//  High-rate topics (cursorPosition ~30–60Hz, gazeFocus ~15–30Hz) flow through the same socket;
//  they are delivered latest-wins to the handler so they never starve the loop topics. (The G5/G7
//  consumers coalesce per topic; the menu store simply ignores them.)
//
//  Connects to the handshake endpoint when present (sends the token first frame), else the G0
//  fixed dev port with no token (BridgeHandshake). An undecodable frame is dropped + logged, never
//  fatal — a single drifted frame must not kill the stream.
//

import Foundation

actor BridgeConnection {
    private let session = URLSession(configuration: .default)
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var onFrame: (@Sendable (BridgeFrame) async -> Void)?
    private var onState: (@Sendable (ConnectionState) async -> Void)?

    /// Start the connect/receive/reconnect loop. Idempotent — a second call is ignored.
    func start(
        onFrame: @escaping @Sendable (BridgeFrame) async -> Void,
        onState: @escaping @Sendable (ConnectionState) async -> Void
    ) {
        guard loop == nil else { return }
        self.onFrame = onFrame
        self.onState = onState
        loop = Task { await self.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// Send a command frame. A write failure tears the socket down so the run loop reconnects.
    func send(_ command: Command) async {
        guard let socket else { return }
        do {
            let data = try command.frameData()
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            #if DEBUG
            print("bridge: send(\(command.topic)) failed: \(error) — reconnecting")
            #endif
            await onState?(.reconnecting)
            socket.cancel(with: .goingAway, reason: nil)
            self.socket = nil
        }
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let endpoint = BridgeHandshake.load()
            await onState?(attempt == 0 ? .connecting : .reconnecting)

            let socket = session.webSocketTask(with: endpoint.url)
            self.socket = socket
            socket.resume()

            // Auth ONLY when the engine advertised a token (a G0 engine has none and would
            // reject an unknown auth frame). Then re-prime latest-wins state.
            if let token = endpoint.token {
                try? await socket.send(.string(authFrame(token)))
            }
            try? await socket.send(.string(#"{"v":1,"type":"command","topic":"getReadiness"}"#))

            await onState?(.connected)
            attempt = 0

            let keepalive = startKeepalive()
            await receiveLoop(socket)
            keepalive.cancel()

            self.socket = nil
            if Task.isCancelled { break }
            await onState?(.engineDown)
            attempt += 1
            try? await Task.sleep(for: Self.backoffDelay(attempt: attempt))
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                return // socket dropped (engine down / idle teardown) → caller reconnects
            }
            if case let .string(text) = message, let frame = Self.decode(text) {
                await onFrame?(frame)
            }
        }
    }

    /// Periodic ping so an idle socket is not torn down (URLSession drops idle WS ~6s).
    private func startKeepalive() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.ping()
            }
        }
    }

    private func ping() {
        socket?.sendPing(pongReceiveHandler: { _ in })
    }

    private func authFrame(_ token: String) -> String {
        // Auth-frame shape is co-owned (pending engine confirmation); only sent when the
        // handshake advertised a token, so a G0 engine never sees it.
        let escaped = token.replacingOccurrences(of: "\"", with: "\\\"")
        return #"{"v":1,"type":"command","topic":"auth","payload":{"token":"\#(escaped)"}}"#
    }

    /// Decode a frame; an undecodable/drifted frame is dropped + logged, never fatal.
    static func decode(_ text: String) -> BridgeFrame? {
        do {
            return try JSONDecoder().decode(BridgeFrame.self, from: Data(text.utf8))
        } catch {
            #if DEBUG
            print("bridge: dropped undecodable frame: \(error)")
            #endif
            return nil
        }
    }

    /// Exponential backoff: 250ms, 500, 1000, 2000, 4000, then capped at 5000ms. Pure/testable.
    static func backoffDelay(attempt: Int) -> Duration {
        let shift = min(max(attempt - 1, 0), 5)
        return .milliseconds(min(5000, 250 * (1 << shift)))
    }
}
