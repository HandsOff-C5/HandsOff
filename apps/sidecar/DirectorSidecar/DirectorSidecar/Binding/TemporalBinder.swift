//
//  TemporalBinder.swift
//  DirectorSidecar
//
//  Temporal deixis binder (U6) — PURE. Port of packages/intent/src/binding/temporal-binder.ts.
//
//  One spoken utterance can point at several surfaces in turn ("type Laura in THIS, and hello in
//  THAT"). Given the per-word transcript timeline (U4) and the head/hand pointing traces recorded
//  during the same capture window (CaptureTrace, U5), all on one epoch-ms clock, this binds each
//  deictic word to the surface that was pointed at WHILE THAT WORD WAS SPOKEN — before the model is
//  called — so the multi-target utterance reaches the loop with BOTH referents.
//
//  For each deictic word it picks the pointing sample whose timestamp brackets [startMs, endMs],
//  preferring a locked hand referent over a hand cursor over a head point (and, within a tier,
//  higher confidence). When no sample brackets the word exactly it falls back to the nearest sample
//  inside a gesture-PRECEDES-speech tolerance window (people point a beat before they say "this"). A
//  word with no nearby sample is left UNBOUND rather than mis-bound to the wrong window.
//
//  The TS binder ranked against an `AttentionWindow` (surface + bounds + zIndex); this app's
//  pointable-window shape is `CuaWindow`, which `AttentionRanking.rank` already consumes, so the
//  binder resolves head/hand points through that same ranker and matches a hand candidate's
//  `targetId` against the windows' surface ids.
//

import Foundation

enum TemporalBinder {
    /// The deictic tokens that anchor to a pointed-at surface.
    static let deicticWords: Set<String> = ["this", "that", "here", "there", "these", "those"]

    /// People point a beat before they say the deictic word; allow a gesture up to this far BEFORE
    /// the word to bind when nothing brackets it exactly. Bounded so a stale gesture from much
    /// earlier never binds. (`DEFAULT_GESTURE_PRECEDES_TOLERANCE_MS`.)
    static let defaultGesturePrecedesToleranceMs: Double = 1500

    /// One deictic word's binding outcome. `evidence` is the bound pointing evidence, or nil when no
    /// nearby sample backed the word (→ clarification downstream).
    struct Binding: Equatable, Sendable {
        let word: String
        let startMs: Double
        let endMs: Double
        let evidence: Contracts.PointingEvidence?
    }

    /// True when `text` is a deictic token, case- and punctuation-insensitively.
    static func isDeicticWord(_ text: String) -> Bool {
        deicticWords.contains(normalize(text))
    }

    /// Bind every deictic word in the utterance to the surface pointed at while it was spoken. Words
    /// are returned in transcript order; non-deictic words are skipped. (`bindTemporalDeixis`.)
    static func bind(
        words: [Contracts.TranscriptWord],
        headTrace: [HeadTraceSample],
        handTrace: [HandTraceSample],
        windows: [CuaWindow],
        toleranceMs: Double = defaultGesturePrecedesToleranceMs,
        headRadius: Double? = nil
    ) -> [Binding] {
        words
            .filter { isDeicticWord($0.text) }
            .map {
                bindWord(
                    $0, headTrace: headTrace, handTrace: handTrace, windows: windows,
                    toleranceMs: toleranceMs, headRadius: headRadius)
            }
    }

    // MARK: - Per-word binding

    private static func bindWord(
        _ word: Contracts.TranscriptWord,
        headTrace: [HeadTraceSample],
        handTrace: [HandTraceSample],
        windows: [CuaWindow],
        toleranceMs: Double,
        headRadius: Double?
    ) -> Binding {
        let normalized = normalize(word.text)

        // Tier 1+2: hand lock / hand cursor.
        if let hand = pickHandSample(handTrace, word.startMs, word.endMs, toleranceMs),
            let candidate = hand.candidate {
            // Prefer the candidate's exact resolved surface (when the gesture lane already resolved a
            // window id). When that targetId doesn't match a pointable window — e.g. the lane
            // resolved a DISPLAY id while the windows are real app windows — fall back to the
            // frontmost window under the hand point, the same point→window resolution the head tier
            // uses. This keeps the precise hand (the primary modality) bound to a real window instead
            // of dropping to a whole display.
            let surface =
                surfaceForTargetId(candidate.targetId, windows)
                ?? rankPoint(x: hand.x, y: hand.y, windows: windows, radius: headRadius).first?.surface
            if let surface {
                return Binding(
                    word: normalized, startMs: word.startMs, endMs: word.endMs,
                    evidence: Contracts.PointingEvidence(
                        source: .fusion,
                        confidence: candidate.confidence,
                        strategy: "temporal-bind:\(normalized)@\(msLabel(hand.tsMs))",
                        surface: surface,
                        cursor: nil))
            }
        }

        // Tier 3: head point, ranked into a scored surface.
        if let head = pickHeadSample(headTrace, word.startMs, word.endMs, toleranceMs) {
            if let top = rankPoint(x: head.x, y: head.y, windows: windows, radius: headRadius).first {
                return Binding(
                    word: normalized, startMs: word.startMs, endMs: word.endMs,
                    evidence: Contracts.PointingEvidence(
                        source: .fusion,
                        confidence: top.score,
                        strategy: "temporal-bind:\(normalized)@\(msLabel(head.tsMs))",
                        surface: top.surface,
                        cursor: nil))
            }
        }

        // No nearby pointing sample resolved a surface — leave it unbound.
        return Binding(word: normalized, startMs: word.startMs, endMs: word.endMs, evidence: nil)
    }

    // MARK: - Sample selection

    /// Pick the best hand sample for a word: prefer one that brackets exactly over one in the
    /// tolerance window, prefer `locked` phase over any other, then higher candidate confidence, then
    /// the sample nearest the word's start. Only samples that carry a candidate are eligible.
    private static func pickHandSample(
        _ samples: [HandTraceSample], _ startMs: Double, _ endMs: Double, _ toleranceMs: Double
    ) -> HandTraceSample? {
        let eligible = samples.filter {
            $0.candidate != nil && withinWindow($0.tsMs, startMs, endMs, toleranceMs)
        }
        guard !eligible.isEmpty else { return nil }

        func rank(_ s: HandTraceSample) -> [Double] {
            [
                bracketsExactly(s.tsMs, startMs, endMs) ? 1 : 0,
                s.phase == .locked ? 1 : 0,
                s.candidate?.confidence ?? 0,
                -abs(s.tsMs - startMs),
            ]
        }
        // Stable descending sort so the first sample among ties (nearest in transcript order) wins,
        // matching the TS stable-sort `[0]`.
        return eligible.sorted { compareRank(rank($0), rank($1)) > 0 }.first
    }

    /// Pick the best head sample for a word by the same exact-vs-tolerance preference, then proximity
    /// to the word's start (head confidence feeds the ranker, not this choice).
    private static func pickHeadSample(
        _ samples: [HeadTraceSample], _ startMs: Double, _ endMs: Double, _ toleranceMs: Double
    ) -> HeadTraceSample? {
        let eligible = samples.filter { withinWindow($0.tsMs, startMs, endMs, toleranceMs) }
        guard !eligible.isEmpty else { return nil }

        func rank(_ s: HeadTraceSample) -> [Double] {
            [
                bracketsExactly(s.tsMs, startMs, endMs) ? 1 : 0,
                -abs(s.tsMs - startMs),
            ]
        }
        return eligible.sorted { compareRank(rank($0), rank($1)) > 0 }.first
    }

    // MARK: - Helpers

    /// Strip every non-letter and lowercase, so "this," / "This" match. (TS `/[^\p{L}]/gu`.)
    private static func normalize(_ text: String) -> String {
        text.lowercased().filter(\.isLetter)
    }

    /// True when `tsMs` falls inside [start, end], or inside the gesture-precedes window
    /// [start - tolerance, end] used only as a fallback.
    private static func withinWindow(
        _ tsMs: Double, _ startMs: Double, _ endMs: Double, _ toleranceMs: Double
    ) -> Bool {
        tsMs >= startMs - toleranceMs && tsMs <= endMs
    }

    private static func bracketsExactly(_ tsMs: Double, _ startMs: Double, _ endMs: Double) -> Bool {
        tsMs >= startMs && tsMs <= endMs
    }

    /// Lexicographic compare of fixed-length numeric rank tuples (higher is better). Returns >0 when
    /// `a` outranks `b`. (TS `compareRank`.)
    private static func compareRank(_ a: [Double], _ b: [Double]) -> Double {
        for i in 0..<Swift.max(a.count, b.count) {
            let diff = (i < a.count ? a[i] : 0) - (i < b.count ? b[i] : 0)
            if diff != 0 { return diff }
        }
        return 0
    }

    private static func surfaceForTargetId(
        _ targetId: String, _ windows: [CuaWindow]
    ) -> Contracts.SurfaceSnapshot? {
        windows.first { $0.surface.id == targetId }?.surface
    }

    /// Rank the windows around a 2D pointing point through the shared head-attention ranker. The
    /// point is incidental here (hand or head); `AttentionRanking.rank` takes a `HeadPoint` only as a
    /// 2D `{x, y}` carrier — confidence/yaw/pitch/ts are unused by the ranker.
    private static func rankPoint(
        x: Double, y: Double, windows: [CuaWindow], radius: Double?
    ) -> [Contracts.AttentionRegionCandidate] {
        let point = HeadPoint(x: x, y: y, yaw: nil, pitch: nil, confidence: 0, ts: 0)
        return AttentionRanking.rank(
            point: point, windows: windows, radius: radius ?? AttentionRanking.defaultRadius)
    }

    /// Format an epoch-ms timestamp into the strategy label the way JS `Number.toString` does —
    /// integral ms print without a decimal (`temporal-bind:this@1100`), matching the TS strategy
    /// string the audit/eval assert against.
    private static func msLabel(_ ms: Double) -> String {
        ms == ms.rounded() && abs(ms) < 1e15 ? String(Int64(ms)) : String(ms)
    }
}
