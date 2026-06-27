// VoiceActionCoordinatorTests — the Beat 1 look+voice capture→drop flow, driven through a fake
// environment that records every injected side effect. Pure orchestration (no AX, no pasteboard, no
// camera), so it runs headlessly. Covers wake gating, capture, paste, cross-utterance referent
// memory, the owner-gate decisions, and sleep clearing.

import Testing
import CoreGraphics
@testable import DirectorSidecar

@MainActor
struct VoiceActionCoordinatorTests {

    /// Records every side effect the coordinator fires, so tests assert on calls instead of on real
    /// subsystems.
    final class Recorder {
        var point: CGPoint? = CGPoint(x: 100, y: 200)
        var textUnderGaze: String? = "let x = 1"
        var frameUnderGaze: CGRect? = CGRect(x: 10, y: 20, width: 300, height: 80)
        var ownerDecision: OwnerGate.Decision = .bypassed

        /// When false, `focusElement` reports it could NOT place the caret (best-effort failure path).
        var focusSucceeds = true

        var clipboardWrites: [ClipboardContent] = []
        var pasteCount = 0
        var brackets: [(rect: CGRect, confirmed: Bool)] = []
        var logs: [String] = []
        var focusedPoints: [CGPoint] = []
        var auditEvents: [String] = []
        /// An ordered trace of the side effects whose RELATIVE order matters (focus must precede paste).
        var callOrder: [String] = []

        func makeEnvironment() -> VoiceActionEnvironment {
            VoiceActionEnvironment(
                currentPoint: { self.point },
                readText: { _ in self.textUnderGaze },
                elementFrame: { _ in self.frameUnderGaze },
                writeClipboard: { self.clipboardWrites.append($0) },
                focusElement: { point in
                    self.focusedPoints.append(point)
                    self.callOrder.append("focus")
                    return self.focusSucceeds
                },
                paste: { self.pasteCount += 1; self.callOrder.append("paste") },
                showBrackets: { self.brackets.append((rect: $0, confirmed: $1)) },
                ownerVerify: { self.ownerDecision },
                log: { self.logs.append($0) },
                audit: { self.auditEvents.append($0) }
            )
        }
    }

    private func make() -> (VoiceActionCoordinator, Recorder) {
        let rec = Recorder()
        return (VoiceActionCoordinator(environment: rec.makeEnvironment()), rec)
    }

    // MARK: - Wake gating

    @Test func noWakePhrase_returnsFalse_noSideEffects() {
        let (coord, rec) = make()
        #expect(coord.handle(transcript: "copy this") == false)
        #expect(rec.clipboardWrites.isEmpty)
        #expect(rec.pasteCount == 0)
        #expect(rec.brackets.isEmpty)
        #expect(coord.pending == nil)
    }

    @Test func wakeButNonBeat1Command_returnsFalse() {
        let (coord, rec) = make()
        #expect(coord.handle(transcript: "hey director open safari") == false)
        #expect(rec.clipboardWrites.isEmpty)
    }

    // MARK: - Capture

    @Test func capture_setsPending_showsConfirmedBrackets_noClipboardWrite() {
        let (coord, rec) = make()
        rec.textUnderGaze = "func greet() {}"
        let consumed = coord.handle(transcript: "hey director copy this")

        #expect(consumed)
        #expect(coord.pending == .codeBlock(heading: nil, code: "func greet() {}", language: nil))
        #expect(rec.clipboardWrites.isEmpty)  // capture only buffers; the write happens on drop
        #expect(rec.pasteCount == 0)
        #expect(rec.brackets.count == 1)
        #expect(rec.brackets.first?.rect == rec.frameUnderGaze)
        #expect(rec.brackets.first?.confirmed == true)
    }

    @Test func capture_nothingUnderGaze_consumedButNoPending() {
        let (coord, rec) = make()
        rec.textUnderGaze = nil
        #expect(coord.handle(transcript: "hey director grab this"))
        #expect(coord.pending == nil)
        #expect(rec.logs.contains { $0.contains("nothing under gaze") })
    }

    // MARK: - Paste

    @Test func paste_withPriorCapture_writesBufferedContent_andPastes() {
        let (coord, rec) = make()
        rec.textUnderGaze = "x"
        _ = coord.handle(transcript: "hey director copy this")

        let consumed = coord.handle(transcript: "hey director drop it here")
        #expect(consumed)
        #expect(rec.clipboardWrites.count == 1)
        #expect(rec.clipboardWrites.first == .codeBlock(heading: nil, code: "x", language: nil))
        #expect(rec.pasteCount == 1)
        // Finding 4: keyboard focus is shifted to the gazed drop target BEFORE the paste fires, so
        // Cmd+V lands in it and not whatever control was previously focused.
        #expect(rec.focusedPoints.count == 1)
        #expect(rec.callOrder == ["focus", "paste"])
    }

    @Test func paste_focusFailure_stillPastes_andLogs() {
        let (coord, rec) = make()
        rec.textUnderGaze = "x"
        _ = coord.handle(transcript: "hey director copy this")

        rec.focusSucceeds = false  // focus is best-effort — a failure must NOT abort the paste
        #expect(coord.handle(transcript: "hey director drop it here"))
        #expect(rec.pasteCount == 1)
        #expect(rec.callOrder == ["focus", "paste"])
        #expect(rec.logs.contains { $0.contains("focus") })
    }

    @Test func paste_withNoPriorCapture_consumed_logsNothingCaptured_noEffects() {
        let (coord, rec) = make()
        let consumed = coord.handle(transcript: "hey director drop it here")
        #expect(consumed)
        #expect(rec.clipboardWrites.isEmpty)
        #expect(rec.pasteCount == 0)
        #expect(rec.logs.contains { $0.contains("nothing captured") })
    }

    // MARK: - Cross-utterance referent memory (the core Beat 1 behavior)

    @Test func captureThenPaste_onSameCoordinator_pastesCapturedContent() {
        let (coord, rec) = make()
        rec.textUnderGaze = "README code block"
        rec.frameUnderGaze = CGRect(x: 5, y: 5, width: 200, height: 60)
        #expect(coord.handle(transcript: "hey director copy this"))

        // Move gaze to the Slack composer and drop.
        rec.point = CGPoint(x: 900, y: 700)
        rec.textUnderGaze = nil  // the drop does not re-read text; it uses the buffer
        #expect(coord.handle(transcript: "hey director drop it here"))

        #expect(rec.clipboardWrites == [.codeBlock(heading: nil, code: "README code block", language: nil)])
        #expect(rec.pasteCount == 1)
        // Pending survives the drop so the user can drop again.
        #expect(coord.pending == .codeBlock(heading: nil, code: "README code block", language: nil))
    }

    // MARK: - Owner gate

    @Test func ownerDenied_refusesCapture_pendingStaysNil() {
        let (coord, rec) = make()
        rec.ownerDecision = .denied(reason: "below threshold")
        #expect(coord.handle(transcript: "hey director copy this"))  // consumed but refused
        #expect(coord.pending == nil)
        #expect(rec.clipboardWrites.isEmpty)
        #expect(rec.logs.contains { $0.contains("owner-gate denied") })
        // Finding 3: a denial is recorded in the tamper-evident audit chain too, not just OSLog.
        #expect(rec.auditEvents.contains("owner-gate-denied"))
    }

    @Test func ownerBypassed_proceeds_andLogsBypassMarker() {
        let (coord, rec) = make()
        rec.ownerDecision = .bypassed
        rec.textUnderGaze = "code"
        #expect(coord.handle(transcript: "hey director copy this"))
        #expect(coord.pending == .codeBlock(heading: nil, code: "code", language: nil))
        // The bypass must be visible in the log — never a silent admit.
        #expect(rec.logs.contains { $0.contains("bypass") })
        // Finding 3: and it must ALSO go through the SHA-256 hash-chained audit, so the bypass is
        // tamper-evident — proving it is not OSLog-only (a forgeable trace).
        #expect(rec.auditEvents.contains("owner-gate-bypass"))
    }

    // MARK: - Sleep

    @Test func sleepCommand_clearsPending_andIsConsumed() {
        let (coord, rec) = make()
        rec.textUnderGaze = "buffered"
        #expect(coord.handle(transcript: "hey director copy this"))
        #expect(coord.pending != nil)

        #expect(coord.handle(transcript: "hey director stop listening"))
        #expect(coord.pending == nil)
    }

    // MARK: - Pure classifier

    @Test func classify_pureKeywordMatching() {
        #expect(VoiceActionCoordinator.classify("copy this") == .capture)
        #expect(VoiceActionCoordinator.classify("grab that") == .capture)
        #expect(VoiceActionCoordinator.classify("drop it here") == .paste)
        #expect(VoiceActionCoordinator.classify("paste") == .paste)
        #expect(VoiceActionCoordinator.classify("put it there") == .paste)
        // Finding 5: an explicit verbless deictic "it here"/"it there" still pastes …
        #expect(VoiceActionCoordinator.classify("it here") == .paste)
        #expect(VoiceActionCoordinator.classify("it there") == .paste)
        // … but a BARE "here"/"there" no longer does (it over-matched questions like "what is here").
        #expect(VoiceActionCoordinator.classify("here") == .none)
        #expect(VoiceActionCoordinator.classify("there") == .none)
        #expect(VoiceActionCoordinator.classify("open safari") == .none)
    }

    // MARK: - Classifier narrowing (Finding 5) — end-to-end through `handle`

    @Test func bareHereQuestion_isNotPaste_soNotConsumed() {
        let (coord, rec) = make()
        rec.textUnderGaze = "x"
        _ = coord.handle(transcript: "hey director copy this")  // arm a pending capture
        rec.pasteCount = 0

        // "what is here" is a question, not a drop — it must NOT trigger a paste, and (being a wake
        // command we don't own) falls through for other routing.
        #expect(coord.handle(transcript: "hey director what is here") == false)
        #expect(rec.pasteCount == 0)
        #expect(rec.clipboardWrites.isEmpty)
    }

    @Test func verbPaste_overHere_stillPastes() {
        let (coord, rec) = make()
        rec.textUnderGaze = "x"
        _ = coord.handle(transcript: "hey director copy this")

        // An explicit paste verb ("put") pastes even with extra words around "here".
        #expect(coord.handle(transcript: "hey director put it over here"))
        #expect(rec.pasteCount == 1)
    }
}
