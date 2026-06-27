// WakePhraseTests — the "Hey Director" wake/sleep text detection (mishears, in-breath commands,
// stop words). Pure/static, no mic. Ported from the engine's ActuationRuntime suite.

import Testing
@testable import DirectorSidecar

struct WakePhraseTests {

    @Test func detectWake_bare() {
        #expect(WakePhrase.detectWake("Hey Director") == "")
        #expect(WakePhrase.detectWake("hey director.") == "")
    }

    @Test func detectWake_inBreathCommand() {
        #expect(WakePhrase.detectWake("Hey Director, open Safari") == "open safari")
        #expect(WakePhrase.detectWake("director open notes") == "open notes")
    }

    @Test func detectWake_mishears() {
        // STT mis-hears "director" — fuzzy still wakes.
        #expect(WakePhrase.detectWake("hey directer open mail") == "open mail")
        #expect(WakePhrase.detectWake("okay director") != nil)
    }

    @Test func detectWake_absent() {
        #expect(WakePhrase.detectWake("what time is it") == nil)
        #expect(WakePhrase.detectWake("open safari") == nil)  // no wake phrase → not a wake
    }

    @Test func isSleep() {
        #expect(WakePhrase.isSleep("off"))
        #expect(WakePhrase.isSleep("stop listening"))
        #expect(WakePhrase.isSleep("go to sleep"))
        #expect(WakePhrase.isSleep("never mind"))
        #expect(!WakePhrase.isSleep("open safari"))
        #expect(!WakePhrase.isSleep("turn off the lights")) // not a bare stop word
    }

    // Token-boundary matching: sleep phrases must match on whole-word edges, not as
    // character substrings inside other words.
    @Test func isSleep_tokenBoundary() {
        // True positives — exact whole-utterance matches (all existing phrases still work).
        #expect(WakePhrase.isSleep("director off"))
        #expect(WakePhrase.isSleep("director stop"))
        #expect(WakePhrase.isSleep("go to bed"))
        #expect(WakePhrase.isSleep("stop it"))

        // Multi-token phrase embedded in a longer utterance — still matches at token edges.
        #expect(WakePhrase.isSleep("please stop listening"))
        #expect(WakePhrase.isSleep("please go to sleep"))

        // False positives that the old `contains` approach produced — must now be false.
        // "director off" as character prefix of "offline" is NOT a sleep command.
        #expect(!WakePhrase.isSleep("director offline"))
        // "off" is a character prefix of "offended" — not a stop word boundary.
        #expect(!WakePhrase.isSleep("director offended me"))
        // Single-word stop term must not match when embedded inside a longer utterance.
        #expect(!WakePhrase.isSleep("go to sleep mode settings"))
        // Unrelated sentence that doesn't contain any sleep phrase at all.
        #expect(!WakePhrase.isSleep("what time is it"))
    }
}
