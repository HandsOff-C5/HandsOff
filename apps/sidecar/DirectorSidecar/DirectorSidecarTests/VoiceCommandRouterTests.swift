// VoiceCommandRouterTests — the spoken-command PARSE + RESOLVE routing that maps a final transcript
// to the right command ("open Safari" launches; "type x" injects; "move this there" point+drags).
// Pure/static, no mic/AX. Ported from the engine's ActuationRuntime suite (dispatch/actuation lives
// in the loop the director wires, and is out of scope here).

import Testing
@testable import DirectorSidecar

struct VoiceCommandRouterTests {

    private typealias Cmd = VoiceCommandRouter.ParsedCommand

    @Test func parse_open_launchesNamedApp() {
        #expect(VoiceCommandRouter.parseCommand("open Safari") == .launch(appName: "Safari"))
        #expect(VoiceCommandRouter.parseCommand("launch Notes") == .launch(appName: "Notes"))
        #expect(VoiceCommandRouter.parseCommand("start up Terminal") == .launch(appName: "Terminal"))
    }

    @Test func parse_switchTo_focusesApp() {
        #expect(VoiceCommandRouter.parseCommand("switch to Mail") == .focus(appName: "Mail"))
        #expect(VoiceCommandRouter.parseCommand("focus Safari") == .focus(appName: "Safari"))
    }

    @Test func parse_type_keepsBodyVerbatim() {
        #expect(VoiceCommandRouter.parseCommand("type hello world") == .type(text: "hello world"))
    }

    @Test func parse_submit() {
        #expect(VoiceCommandRouter.parseCommand("press enter") == .submit)
        #expect(VoiceCommandRouter.parseCommand("submit") == .submit)
    }

    @Test func parse_explicitCommandBeatsDeixis() {
        // "type this note" must TYPE (explicit), not route to point+drag on the deictic "this".
        #expect(VoiceCommandRouter.parseCommand("type this note") == .type(text: "this note"))
    }

    @Test func parse_deicticMove_routesToPointAndDrag() {
        guard case let .move(spans) = VoiceCommandRouter.parseCommand("move this over there") else {
            Issue.record("expected .move")
            return
        }
        #expect(spans.map(\.text) == ["this", "there"])
    }

    @Test func parse_unrecognized_isNone() {
        #expect(VoiceCommandRouter.parseCommand("what time is it") == .none)
        #expect(VoiceCommandRouter.parseCommand("   ") == .none)
    }

    @Test func resolveBundleId_knownApps() {
        #expect(VoiceCommandRouter.resolveBundleId(forAppNamed: "Safari") == "com.apple.Safari")
        #expect(VoiceCommandRouter.resolveBundleId(forAppNamed: "system settings") == "com.apple.systempreferences")
        #expect(VoiceCommandRouter.resolveBundleId(forAppNamed: "VS Code") == "com.microsoft.VSCode")
    }

    @Test func resolveBundleId_fuzzy_misheardNames() {
        // STT mis-hears: "saferie"/"sefari" must still resolve to Safari (edit distance ≤ threshold).
        #expect(VoiceCommandRouter.resolveBundleId(forAppNamed: "saferie") == "com.apple.Safari")
        #expect(VoiceCommandRouter.resolveBundleId(forAppNamed: "sefari") == "com.apple.Safari")
        // A genuinely unrelated word resolves to nothing (no wrong guess).
        #expect(VoiceCommandRouter.resolveBundleId(forAppNamed: "xqzptv") == nil)
    }

    @Test func editDistance() {
        #expect(EditDistance.levenshtein("safari", "safari") == 0)
        #expect(EditDistance.levenshtein("saferie", "safari") == 2)
    }
}
