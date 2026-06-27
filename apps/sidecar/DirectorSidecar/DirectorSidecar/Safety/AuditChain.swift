//
//  AuditChain.swift
//  DirectorSidecar
//
//  Phase 4a — the SHA-256 hash-chained, append-only AuditLog (engine NFR-8 / M-6 /
//  ARCHITECTURE §9; ported from App/Sources/RuleBook/AuditLog.swift). FILES ONLY — not yet
//  wired into the loop's audit.
//
//  "No silent success": every committed actuation is recorded here with its full evidence —
//  action, args, taint, confidence, the verify result, and the undo token — so a wrong action
//  is always discoverable after the fact. The log is APPEND-ONLY by construction: there is no
//  mutate-in-place and no remove API; `append` is the only writer and entries, once written,
//  are immutable value types.
//
//  TAMPER-EVIDENCE: the log is a HASH CHAIN. Each entry carries a `hash` computed over
//  (prevHash + the entry's committed fields); the next entry chains onto it. Editing or
//  removing any past entry breaks the chain from that point on, so `verifyChain()` detects any
//  after-the-fact tampering. The `append` surface is unchanged — callers pass a plain
//  `AuditEntry`; the chaining is internal. This hash-CHAIN mechanism is what the Director lacks.

import Foundation
import CryptoKit

/// One immutable audit entry for a committed action (evidence: NFR-8). Every field is the
/// post-commit truth; entries are never edited after `append`.
struct AuditEntry: Equatable, Sendable {
    /// The committed action string (`verb` or `verb:target`).
    let action: String
    /// The action's args (each with its own taint) as committed.
    let args: [ActionArg]
    /// The worst-case taint over the action's args (trusted unless any arg is tainted).
    let taint: Taint
    /// The calibrated confidence carried on the action's header at commit time.
    let conf: Double
    /// The verify outcome: did the post-actuation AX re-read match?
    let verified: Bool
    /// The undo token returned for this commit — every commit is undoable.
    let undoToken: UndoToken
    /// The hash of the PREVIOUS entry this one chains onto ("" for the genesis entry). The chain
    /// link — recomputing the chain detects any edit/removal upstream.
    internal(set) var prevHash: String
    /// This entry's hash over (`prevHash` + its committed fields). The tamper-evidence anchor.
    internal(set) var hash: String

    init(
        action: String,
        args: [ActionArg],
        taint: Taint,
        conf: Double,
        verified: Bool,
        undoToken: UndoToken,
        prevHash: String = "",
        hash: String = ""
    ) {
        self.action = action
        self.args = args
        self.taint = taint
        self.conf = conf
        self.verified = verified
        self.undoToken = undoToken
        self.prevHash = prevHash
        self.hash = hash
    }

    /// The canonical, order-stable string fingerprint of the COMMITTED fields (no hashes).
    /// Hashing `prevHash + this` yields the chain link, so any field edit changes the hash.
    var fingerprint: String {
        let argString = args
            .map { "\($0.name)=\($0.value):\($0.taint.rawValue)" }
            .joined(separator: ",")
        return "action=\(action)|args=[\(argString)]|taint=\(taint.rawValue)|conf=\(conf)|verified=\(verified)|undo=\(undoToken.id)/\(undoToken.action)"
    }
}

/// The append-only audit log. A `final class` so the loop holds one shared, growing record; the
/// ONLY mutation is `append`, which is additive. No element of `entries` is ever mutated or
/// removed (the append-only invariant, M-6 / NFR-8).
final class AuditLog {
    /// The ordered, immutable record. Exposed read-only — there is no setter, no `remove`, no
    /// subscript-set; callers can only observe it.
    private(set) var entries: [AuditEntry] = []

    init() {}

    /// Append one committed-action entry. The sole writer; strictly additive. The caller passes a
    /// plain `AuditEntry` (unchanged surface) — `append` stamps the chain link: `prevHash` = the
    /// last entry's hash, `hash` = SHA-256(prevHash + fingerprint).
    func append(_ entry: AuditEntry) {
        var chained = entry
        chained.prevHash = entries.last?.hash ?? ""
        chained.hash = Self.linkHash(prev: chained.prevHash, fingerprint: chained.fingerprint)
        entries.append(chained)
    }

    /// Verify the whole chain (tamper-evidence). Recomputes each link from its stored `prevHash` +
    /// fingerprint and checks (a) the stored hash matches and (b) each entry's `prevHash` equals
    /// the previous entry's hash. Any edit or removal breaks one of these.
    func verifyChain() -> Bool {
        var expectedPrev = ""
        for entry in entries {
            guard entry.prevHash == expectedPrev else { return false }
            let recomputed = Self.linkHash(prev: entry.prevHash, fingerprint: entry.fingerprint)
            guard entry.hash == recomputed else { return false }
            expectedPrev = entry.hash
        }
        return true
    }

    /// Load a chain AS-IS (no re-stamping), modelling a read-back from the persistent on-disk log.
    /// `verifyChain()` then validates the loaded entries — this is the seam a tamper test (or the
    /// live disk reader) uses to present a possibly-edited chain.
    func loadForVerification(_ loaded: [AuditEntry]) {
        entries = loaded
    }

    /// SHA-256 of (prevHash + "\n" + fingerprint), hex-encoded. The chain link primitive.
    static func linkHash(prev: String, fingerprint: String) -> String {
        let data = Data((prev + "\n" + fingerprint).utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Number of recorded commits — handy for the "exactly one entry" assertion.
    var count: Int { entries.count }
}
