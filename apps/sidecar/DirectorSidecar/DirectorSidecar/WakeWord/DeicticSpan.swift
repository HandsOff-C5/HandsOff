// DeicticSpan — a deictic word ("this"/"that"/"there"/"here"/"it") with its token offsets into a
// transcript. Localized value type (internal): per repo convention we do NOT import the engine's
// Envelope module — we mirror only the fields the router needs to route a point+drag turn.

import Foundation

/// A deictic span with token offsets into the transcript.
nonisolated struct DeicticSpan: Equatable, Sendable {
    var text: String
    var start: Int
    var end: Int
}
