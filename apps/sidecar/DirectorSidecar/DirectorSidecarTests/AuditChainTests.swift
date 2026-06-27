//
//  AuditChainTests.swift
//  DirectorSidecarTests
//
//  Phase 4a — the SHA-256 hash-chained, append-only AuditLog (NFR-8 / M-6). Append is the only
//  writer; entries accumulate in order and are never mutated or removed. The chain is
//  tamper-evident: editing or removing any past entry breaks verifyChain(). Ported from
//  App/Tests/RuleBookTests/AuditLogTests.swift + ObservabilityTests.swift.

import Testing
@testable import DirectorSidecar

struct AuditChainTests {

    private func entry(_ action: String) -> AuditEntry {
        AuditEntry(
            action: action,
            args: [ActionArg(name: "bundleId", value: "com.apple.Safari", taint: .trusted)],
            taint: .trusted,
            conf: 0.95,
            verified: true,
            undoToken: UndoToken(id: "undo-\(action)", action: action)
        )
    }

    // Append is the only writer; entries accumulate in order.
    @Test func appendIsAdditiveAndOrdered() {
        let log = AuditLog()
        #expect(log.count == 0)
        log.append(entry("launch"))
        log.append(entry("focus"))
        #expect(log.count == 2)
        #expect(log.entries.map(\.action) == ["launch", "focus"])
    }

    // Append-only: an earlier entry is never mutated or removed by a later append — the first
    // STORED entry (including its stamped hash-chain link) is unchanged after subsequent appends.
    @Test func appendOnlyNoMutationOrRemoval() {
        let log = AuditLog()
        log.append(entry("launch"))
        let storedFirst = log.entries[0]
        #expect(storedFirst.action == "launch")
        #expect(storedFirst.prevHash == "")               // genesis chains onto nothing
        #expect(!storedFirst.hash.isEmpty)                // the stored entry is chain-stamped

        log.append(entry("focus"))
        log.append(entry("move"))

        #expect(log.entries[0] == storedFirst)            // first entry still present, identical
        #expect(log.count == 3)                           // nothing removed; count only grows
        #expect(log.entries.map(\.action) == ["launch", "focus", "move"])
    }

    // Append produces a VALID chain: each link verifies end-to-end.
    @Test func appendProducesValidChain() {
        let log = AuditLog()
        for i in 0..<3 { log.append(entry("act-\(i)")) }
        #expect(log.verifyChain())                        // an untampered chain verifies
        #expect(!log.entries[1].hash.isEmpty)
        #expect(log.entries[1].prevHash == log.entries[0].hash)   // links chain forward
    }

    // M-6 tamper-evidence: EDITING a committed field of a past entry (flipping `verified`
    // true→false while keeping the stored hash) breaks the chain — verifyChain returns false.
    @Test func verifyChain_detectsEditedEntry() {
        let log = AuditLog()
        for i in 0..<3 { log.append(entry("act-\(i)")) }
        #expect(log.verifyChain())

        var tampered = log.entries
        let victim = tampered[1]
        tampered[1] = AuditEntry(
            action: victim.action,
            args: victim.args,
            taint: victim.taint,
            conf: victim.conf,
            verified: false,                 // <-- the silent edit
            undoToken: victim.undoToken,
            prevHash: victim.prevHash,
            hash: victim.hash                // <-- stale hash left behind
        )

        let reloaded = AuditLog()
        reloaded.loadForVerification(tampered)
        #expect(!reloaded.verifyChain())     // an edited entry breaks the chain
    }

    // M-6: REMOVING an entry also breaks the chain (the next prevHash no longer matches).
    @Test func verifyChain_detectsRemovedEntry() {
        let log = AuditLog()
        for i in 0..<3 { log.append(entry("act-\(i)")) }

        var truncated = log.entries
        truncated.remove(at: 1)              // drop the middle entry

        let reloaded = AuditLog()
        reloaded.loadForVerification(truncated)
        #expect(!reloaded.verifyChain())     // a removed entry breaks the chain
    }
}
