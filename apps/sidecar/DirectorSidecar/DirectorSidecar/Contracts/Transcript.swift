//
//  Transcript.swift
//  DirectorSidecar
//
//  Port of the @handsoff/contracts transcript.ts shapes the intent contract embeds:
//  `finalTranscriptSchema` + `transcriptWordSchema`. Only the FINAL transcript is modeled
//  here (it is what `IntentInput.speech` carries and the intent engine fuses with the
//  referent); the streaming `SttStream` interface + error taxonomy are runtime STT concerns,
//  not contract decode, and are not ported.
//
//  Distinct from the lite top-level `TranscriptEvent` (Bridge/LoopTypes.swift), which models
//  the HUD's partial|final wire frame with epoch-ms `receivedAt`.
//

import Foundation

extension Contracts {
    /// `transcriptWordSchema`: one recognized word with epoch-ms timing.
    struct TranscriptWord: Codable, Sendable, Equatable {
        let text: String
        let startMs: Double
        let endMs: Double
        let confidence: Double
    }

    /// `finalTranscriptSchema`: a stable, non-revised transcript. `kind` is the literal
    /// "final"; `words` is present only when the provider exposes per-word timing.
    struct FinalTranscript: Decodable, Sendable, Equatable {
        let text: String
        let confidence: Double
        let latencyMs: Double
        let receivedAt: Double
        let words: [TranscriptWord]?

        private enum Key: String, CodingKey {
            case kind, text, confidence, latencyMs, receivedAt, words
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let kind = try c.decode(String.self, forKey: .kind)
            guard kind == "final" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: c,
                    debugDescription: "Expected a final transcript, got kind: \(kind)")
            }
            text = try c.decode(String.self, forKey: .text)
            confidence = try c.decode(Double.self, forKey: .confidence)
            latencyMs = try c.decode(Double.self, forKey: .latencyMs)
            receivedAt = try c.decode(Double.self, forKey: .receivedAt)
            words = try c.decodeIfPresent([TranscriptWord].self, forKey: .words)
        }
    }
}
