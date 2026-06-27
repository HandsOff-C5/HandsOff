// WakePhrase — the text-match wake/sleep detector for "Hey Director" wake mode (no model, no
// account: it scans the on-device STT transcript). `detectWake` recognizes the wake phrase even when
// STT mishears "director" (fuzzy, edit-distance ≤ 2) and returns any command spoken in the SAME
// breath ("hey director open safari" → "open safari"); `isSleep` recognizes the spoken stop words.
// All matching is local; non-wake speech is never acted on or surfaced (the loop discards it).
//
// This augments the existing fn double-tap engage path — it does not replace it. Wire it where
// SpeechService emits a FINAL transcript (see the integration note in the port report).

import Foundation

nonisolated enum WakePhrase {

    /// Greeting tokens that may precede "director" in the wake phrase (or none, if it leads).
    private static let greetings: Set<String> = ["hey", "hay", "hi", "hello", "okay", "ok", "a", "yo"]

    /// Spoken stop words (whole-utterance) that put it back to sleep while awake.
    private static let sleepExact: Set<String> = [
        "off", "stop", "sleep", "quiet", "pause", "never mind", "nevermind",
        "thats all", "that is all", "stop it", "director off", "director stop",
        "stop listening", "go to sleep", "go to bed",
    ]

    /// If `raw` contains the wake phrase, return the command spoken after it (possibly "" when the
    /// user only said the wake phrase). nil → no wake phrase present.
    static func detectWake(_ raw: String) -> String? {
        let norm = normalize(raw)
        guard !norm.isEmpty else { return nil }
        let tokens = norm.split(separator: " ").map(String.init)
        for (i, token) in tokens.enumerated() where isDirector(token) {
            let leadsOrGreeted = (i == 0) || greetings.contains(tokens[i - 1])
            if leadsOrGreeted {
                return tokens[(i + 1)...].joined(separator: " ")
            }
        }
        return nil
    }

    /// Whether `raw` is a spoken stop command (only consulted while awake).
    static func isSleep(_ raw: String) -> Bool {
        let norm = normalize(raw)
        if sleepExact.contains(norm) { return true }
        return norm.contains("stop listening") || norm.contains("go to sleep") || norm.contains("director off")
    }

    /// "director" or a near-mishear of it (STT often returns "directer"/"directory").
    private static func isDirector(_ token: String) -> Bool {
        token == "director" || EditDistance.levenshtein(token, "director") <= 2
    }

    /// Lowercase, non-alphanumerics → spaces, collapse runs — so punctuation/casing never blocks a match.
    static func normalize(_ s: String) -> String {
        let mapped = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }
}
