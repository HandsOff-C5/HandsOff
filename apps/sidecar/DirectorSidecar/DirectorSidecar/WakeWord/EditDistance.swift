// EditDistance — Levenshtein (insert/delete/substitute) over Characters. The shared fuzzy metric for
// the wake-word stack: it lets "director" survive STT mishears ("directer") and resolves misheard app
// names ("saferie" → "safari"). Pure/static, no dependencies — ported standalone from the engine.

import Foundation

nonisolated enum EditDistance {

    /// Levenshtein edit distance between two strings (number of single-character edits to turn `a`
    /// into `b`). O(|a|·|b|) time, O(|b|) space.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }
}
