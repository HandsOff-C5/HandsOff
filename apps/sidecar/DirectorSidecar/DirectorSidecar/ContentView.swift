//
//  ContentView.swift
//  DirectorSidecar
//
//  G0 readiness window — pulls the 6 macOS capabilities live from the Director engine
//  over the loopback bridge and renders them. Refresh re-queries the engine.
//

import SwiftUI

struct ContentView: View {
    @State private var caps: [CapabilityProbe] = []
    @State private var errorText: String?
    private let client = BridgeClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Director — engine readiness").font(.headline)
            if let errorText { Text(errorText).font(.callout).foregroundStyle(.red) }
            ForEach(caps) { cap in
                HStack {
                    Text(cap.id)
                    Spacer()
                    Text(cap.state).monospaced().foregroundStyle(color(for: cap.state))
                }
            }
            Button("Refresh") { Task { await load() } }.keyboardShortcut("r")
        }
        .padding(20)
        .frame(width: 340)
        .task { await load() }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "granted", "running": return .green
        case "denied", "restricted": return .red
        default: return .secondary
        }
    }

    private func load() async {
        do {
            caps = try await client.requestReadiness().capabilities
            errorText = nil
        } catch {
            errorText = "\(error)"
        }
    }
}

#Preview {
    ContentView()
}
