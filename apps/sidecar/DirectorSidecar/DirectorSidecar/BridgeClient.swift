//
//  BridgeClient.swift
//  DirectorSidecar
//
//  Loopback client for the Director engine bridge (G0). An `actor` so its state is never
//  raced. Connects to the 127.0.0.1 IP literal (ATS does not apply to IP literals) and
//  sends no Origin header — the engine rejects any client that does.
//
//  Readiness is request/response, so each call uses a FRESH short-lived WebSocket: a
//  memoized socket goes stale when idle (URLSession tears it down after ~6s) and the next
//  call fails with ENOTCONN ("Socket is not connected"). G1/G2's streaming state will
//  instead hold a persistent connection with reconnect — a different method from this poll.
//

import Foundation

enum BridgeError: Error { case badFrame(String) }

actor BridgeClient {
    private let url = URL(string: "ws://127.0.0.1:51703")!

    func requestReadiness() async throws -> ReadinessPayload {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() } // close the socket; no stale reuse
        let task = session.webSocketTask(with: url)
        task.resume()

        try await task.send(.string(#"{"v":1,"type":"command","topic":"getReadiness"}"#))
        for _ in 0..<5 { // receive() yields one frame per call; skip anything unexpected
            guard case let .string(text) = try await task.receive() else { continue }
            #if DEBUG
            print("bridge frame: \(text.prefix(300))")
            #endif
            switch try JSONDecoder().decode(BridgeFrame.self, from: Data(text.utf8)) {
            case let .state(topic, readiness) where topic == "readiness":
                guard let readiness else { throw BridgeError.badFrame("readiness state missing payload") }
                return readiness
            case let .error(reason):
                throw BridgeError.badFrame("engine error: \(reason)")
            default:
                continue
            }
        }
        throw BridgeError.badFrame("no readiness frame received")
    }
}
