//
//  BridgeClient.swift
//  DirectorSidecar
//
//  Loopback client for the Director engine bridge (G0). An `actor` so its socket state
//  is never raced. Connects to the 127.0.0.1 IP literal (ATS does not apply to IP
//  literals, so no Info.plist exception is needed) and sends no Origin header — the
//  engine rejects any client that does (browser / DNS-rebind defense).
//

import Foundation

enum BridgeError: Error { case badFrame(String) }

actor BridgeClient {
    private let url = URL(string: "ws://127.0.0.1:51703")!
    private var task: URLSessionWebSocketTask?

    private func ensureConnected() -> URLSessionWebSocketTask {
        if let task { return task }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6 // bounds a stalled receive()
        let t = URLSession(configuration: config).webSocketTask(with: url)
        t.resume()
        task = t
        return t
    }

    func requestReadiness() async throws -> ReadinessPayload {
        let task = ensureConnected()
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
