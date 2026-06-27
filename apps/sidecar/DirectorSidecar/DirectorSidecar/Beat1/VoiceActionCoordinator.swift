//
//  VoiceActionCoordinator.swift
//  DirectorSidecar
//
//  Beat 1 — the "look + voice" formatted-drop flow, wired end-to-end. Engaged by the wake word
//  "Hey Director", the user copies a README code block from Cursor and drops it into the Slack
//  composer using only their gaze + voice — no clicking, no Cmd-C/Cmd-V by hand. Two cross-utterance
//  steps, with referent memory between them:
//
//    1. (looking at the README block in Cursor) "Hey Director, copy this"
//         → capture the looked-at element's text into a pending formatted clipboard buffer and show
//           element-sized gaze brackets (confirmed) around what was captured.
//    2. (looking at the Slack composer) "Hey Director, drop it here"
//         → write the buffered content to the pasteboard (RTF/HTML/plain) and paste it (Cmd+V).
//
//  The buffer (`pending`) PERSISTS between the two utterances — that cross-utterance referent memory
//  is the core of Beat 1. It is NOT cleared after a paste, so the user can drop the same capture into
//  several targets; only a fresh capture or a sleep command replaces/clears it.
//
//  Orchestration is PURE and unit-testable: every side effect (gaze read, AX text read, clipboard
//  write, paste, bracket render, owner-gate check, logging) is an injected closure on
//  `VoiceActionEnvironment`, matching the repo's seam-injection style. The live composition root in
//  DirectorSidecarApp.swift binds those closures to the real subsystems; tests bind fakes.
//

import Foundation
import CoreGraphics

/// The injected side-effect surface for `VoiceActionCoordinator`. Each closure isolates one effect so
/// the coordinator's decision logic stays pure and testable.
struct VoiceActionEnvironment {
    /// The current gaze/head point in CG-global top-left coords (already flipped), or nil if untracked.
    var currentPoint: () -> CGPoint?
    /// Read the text of the element under a point (AX hit-test → selected text, then full value).
    var readText: (CGPoint) -> String?
    /// The on-screen frame of the element under a point (AX hit-test → frame) — for the gaze brackets.
    var elementFrame: (CGPoint) -> CGRect?
    /// Stage formatted content (RTF/HTML/plain) on the system pasteboard.
    var writeClipboard: (ClipboardContent) -> Void
    /// Synthesize a paste (Cmd+V) into the focused field.
    var paste: () -> Void
    /// Render gaze brackets over a rect; `confirmed` settles them on the captured/targeted referent.
    var showBrackets: (CGRect, Bool) -> Void
    /// Owner-voice authorization for the mutating action. `.auditedBypass` returns `.bypassed` (logged,
    /// never a silent admit) until a real voiceprint source is wired.
    var ownerVerify: () -> OwnerGate.Decision
    /// Diagnostics + audit-bypass logging.
    var log: (String) -> Void
}

/// Drives the Beat 1 capture→drop flow from final STT transcripts. Holds the cross-utterance pending
/// buffer and the injected environment. `@MainActor` because it touches the gaze/overlay + pasteboard
/// surfaces, and is invoked from `LoopEngine.ingestSpeech` which already runs on the main actor.
@MainActor
final class VoiceActionCoordinator {

    /// The captured-but-not-yet-dropped content. Persists across utterances (the Beat 1 referent
    /// memory). Cleared only by a sleep command; replaced by a new capture.
    private(set) var pending: ClipboardContent?

    private let env: VoiceActionEnvironment

    init(environment: VoiceActionEnvironment) {
        self.env = environment
    }

    // MARK: - Entry

    /// Handle a final transcript. Returns `true` iff this consumed the utterance — when true, the
    /// caller MUST NOT also start a goal (the Beat 1 command was handled here). A non-wake utterance,
    /// or a wake command that is not a Beat 1 capture/drop, returns `false` so existing routing runs.
    @discardableResult
    func handle(transcript: String) -> Bool {
        // No wake phrase → not ours; the caller falls through to its existing push-to-talk behavior.
        guard let command = WakePhrase.detectWake(transcript) else { return false }

        // Spoken stop word while awake → forget the captured referent and bow out (consumed).
        if WakePhrase.isSleep(transcript) {
            pending = nil
            env.log("beat1: sleep — pending cleared")
            return true
        }

        switch Self.classify(command) {
        case .capture:
            return handleCapture()
        case .paste:
            return handlePaste()
        case .none:
            // A wake command we don't own (e.g. "open safari") — let other routing handle it.
            return false
        }
    }

    // MARK: - Capture ("copy this")

    private func handleCapture() -> Bool {
        guard authorize(action: "capture") else { return true }

        guard let point = env.currentPoint() else {
            env.log("beat1: capture — no gaze point available")
            return true
        }
        guard let text = env.readText(point), !text.isEmpty else {
            env.log("beat1: capture — nothing under gaze")
            return true
        }

        pending = .codeBlock(heading: nil, code: text, language: nil)
        if let frame = env.elementFrame(point) {
            env.showBrackets(frame, true)
        }
        env.log("beat1: captured \(text.count) chars")
        return true
    }

    // MARK: - Paste ("drop it here")

    private func handlePaste() -> Bool {
        guard let content = pending else {
            env.log("beat1: nothing captured yet")
            return true
        }
        guard authorize(action: "paste") else { return true }

        // Settle the brackets on the drop target if we can resolve one (best-effort; the paste does
        // not depend on it).
        if let point = env.currentPoint(), let frame = env.elementFrame(point) {
            env.showBrackets(frame, true)
        }

        env.writeClipboard(content)
        env.paste()
        env.log("beat1: dropped captured content")
        // Keep `pending` so the user can drop the same capture again into another target.
        return true
    }

    // MARK: - Owner gate

    /// Run the owner-gate check for a mutating action. Returns whether the action may proceed.
    /// `.denied` refuses (the utterance is still consumed); `.bypassed` proceeds but is logged so a
    /// bypass is never silent.
    private func authorize(action: String) -> Bool {
        switch env.ownerVerify() {
        case .admitted:
            return true
        case .bypassed:
            env.log("beat1: owner-gate bypassed (no voiceprint source) for \(action)")
            return true
        case let .denied(reason):
            env.log("beat1: owner-gate denied \(action): \(reason)")
            return false
        }
    }

    // MARK: - Intent classification (pure)

    /// The Beat 1 intents we recognize in a wake command. `internal` (not private) so the pure
    /// classifier is directly unit-testable via `@testable import`.
    enum Intent: Equatable {
        case capture
        case paste
        case none
    }

    private static let captureVerbs = ["copy", "grab", "take", "yank", "snag"]
    private static let pasteVerbs = ["drop", "paste", "put", "place"]

    /// Classify a (post-wake) command by simple keyword matching. Capture verbs win when both appear,
    /// since "copy" is the explicit capture intent; a deictic ("this"/"that"/"it") is typical but not
    /// required. Paste is a paste verb, or a bare drop-sense deictic ("it here"/"here"/"there").
    static func classify(_ command: String) -> Intent {
        let words = Set(WakePhrase.normalize(command).split(separator: " ").map(String.init))
        if captureVerbs.contains(where: words.contains) { return .capture }
        if pasteVerbs.contains(where: words.contains) { return .paste }
        // Bare drop-sense: "here"/"there" (optionally with "it") with no explicit verb.
        if words.contains("here") || words.contains("there") { return .paste }
        return .none
    }
}
