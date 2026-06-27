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
}
