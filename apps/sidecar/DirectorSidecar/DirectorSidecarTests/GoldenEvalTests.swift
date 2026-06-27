//
//  GoldenEvalTests.swift
//  DirectorSidecarTests
//
//  Golden evals for the migration's user-facing agent calls (ADR 0005 § Test and eval
//  gate): voice intent, approval gates, pointing/head evidence, and failed-action
//  recovery. Per the ADR these "can start before implementation as contract tests against
//  fixtures" — so this harness decodes the SAME real fixtures the TypeScript vitest goldens
//  consume and asserts every invariant that is locally derivable in Swift TODAY, before the
//  resolver/loop port lands:
//
//    - approval gates   — RiskLevel policy + the ActionPlan decode-time refine
//    - pointing evidence — SelectedReferent + the plan target surface it flows into
//    - voice intent      — the action projection (kinds + typed text) the resolver emits
//    - failed-action     — the CuaActionResult shapes + the KD2 blocked-reason contract
//
//  Single source of truth: the fixtures are read straight from `packages/intent/src/evals`
//  (no copied JSON, no drift). When the Swift next-tool-call resolver + supervision loop are
//  ported (PORTING.md § Porting Order 3-4), these same fixtures become end-to-end evals:
//  run the resolver, project its output, compare to `expected`. The reserved behavioral
//  hooks are called out inline.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Shared fixture loader

/// Locates the canonical golden-set directory from this test file's compile-time path, so
/// the Swift evals decode the exact JSON the TS goldens use. Trimming a known path suffix is
/// more robust than counting parent directories.
private enum GoldenSet {
    static let evalsDir: URL = {
        let path = #filePath
        let marker = "/apps/sidecar/DirectorSidecar/DirectorSidecarTests/"
        guard let range = path.range(of: marker) else {
            fatalError("Golden harness cannot locate the repo root from \(path)")
        }
        return URL(fileURLWithPath: String(path[path.startIndex..<range.lowerBound]))
            .appendingPathComponent("packages/intent/src/evals", isDirectory: true)
    }()

    static func load<T: Decodable>(_ file: String, as type: T.Type = T.self) throws -> T {
        let data = try Data(contentsOf: evalsDir.appendingPathComponent(file))
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Test-only projections of the ported contract types

extension Contracts.ActionStep {
    /// The wire `kind` discriminant, for golden projection parity with the TS resolver's
    /// `step.kind`. Test-local: whether production needs this accessor is the migration's call.
    var wireKind: String {
        switch self {
        case .inspectWindowState: return "inspect_window_state"
        case .clickElement: return "click_element"
        case .typeText: return "type_text"
        case .setValue: return "set_value"
        case .captureScreenshot: return "capture_screenshot"
        case .launchApp: return "launch_app"
        case .toolCall: return "tool_call"
        }
    }

    /// The dictated text a `type_text` step carries (the TS projection's `actionTexts`).
    var typedText: String? {
        if case let .typeText(_, _, _, text) = self { return text }
        return nil
    }

    /// The surface a step addresses, when it has one (`launch_app` does not).
    var targetSurfaceId: String? {
        switch self {
        case let .inspectWindowState(_, _, target), let .clickElement(_, _, target),
             let .captureScreenshot(_, _, target):
            return target.surface.id
        case let .typeText(_, _, target, _), let .setValue(_, _, target, _):
            return target.surface.id
        case .launchApp, .toolCall:
            return nil
        }
    }
}

extension Contracts.CuaActionResult {
    var statusString: String {
        switch self {
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        case .blocked: return "blocked"
        }
    }

    var blockedReason: String? {
        if case let .blocked(reason, _) = self { return reason }
        return nil
    }
}

// MARK: - voice-cua goldens (rule resolver)

/// A voice-cua-goldens.json record. The `expected` projection's `status`/`intent_type` are
/// kept as raw strings: the resolved-intent status + intent vocabulary ("ready",
/// "clarification_required", "click", …) are NOT yet ported to Swift and are distinct from
/// the run/session `ExecutionStatus` vocabulary (PORTING.md note).
private struct VoiceGolden: Decodable {
    let name: String
    let transcript: String
    let surfaceAvailability: String?
    let expected: Expected

    struct Expected: Decodable {
        let status: String
        let intentType: String?
        let riskLevel: String?
        let requiresApproval: Bool
        let targetAgent: String
        let referentId: String?
        let reason: String?
        let actionKinds: [String]
        let actionTexts: [String]

        private enum CodingKeys: String, CodingKey {
            case status
            case intentType = "intent_type"
            case riskLevel = "risk_level"
            case requiresApproval = "requires_approval"
            case targetAgent = "target_agent"
            case referentId, reason, actionKinds, actionTexts
        }
    }
}

@Test func voiceGoldensApprovalGateMatchesLocalRiskPolicy() throws {
    let goldens: [VoiceGolden] = try GoldenSet.load("voice-cua-goldens.json")
    #expect(!goldens.isEmpty)

    for golden in goldens {
        if let raw = golden.expected.riskLevel {
            // A ready intent: the gate the golden expects MUST equal the gate Swift derives
            // locally from the risk tier — never the model's claim.
            let risk = try #require(RiskLevel(rawValue: raw), "unknown risk tier \(raw) in \(golden.name)")
            #expect(risk.requiresApproval == golden.expected.requiresApproval,
                    "approval gate drift for \(golden.name): \(raw) → \(risk.requiresApproval)")
            #expect(golden.expected.targetAgent == "cua-driver")
        } else {
            // blocked / clarification_required: nothing dispatches, so no approval and no agent.
            #expect(golden.expected.requiresApproval == false, "non-ready golden must not gate: \(golden.name)")
            #expect(golden.expected.targetAgent == "none", "non-ready golden has no agent: \(golden.name)")
            #expect(golden.expected.reason != nil, "non-ready golden states a reason: \(golden.name)")
        }
    }
}

@Test func voiceGoldensRiskTiersDecodeToTheCanonicalVocabulary() throws {
    let goldens: [VoiceGolden] = try GoldenSet.load("voice-cua-goldens.json")
    let tiers = goldens.compactMap(\.expected.riskLevel)
    #expect(!tiers.isEmpty)
    for raw in tiers {
        // Every risk tier a golden references is one of the four canonical contract tiers —
        // the stale `.destructive` vocabulary would fail here.
        #expect(RiskLevel(rawValue: raw) != nil, "golden references non-contract risk tier \(raw)")
    }
}

// MARK: - Quick Pass demo goldens (U8, Phase 1)

/// The Quick Pass demo cases the plan authors test-first (`demo-quick-pass-goldens.json`):
/// Q1 summarize→compose-and-write, Q3 reversible navigation click, Q4 reversible draft-type,
/// Q8a pause (read-only interrupt/control), Q8b replay (read-only audit reveal). Q5
/// ("Send this." → mutating commit) UPDATES the `unsupported send it` voice-cua golden above.
///
/// These cases reuse the `VoiceGolden` shape and the same TS fixture file. Swift asserts only
/// the invariants locally derivable from the fixture TODAY — the approval gate is the one the
/// risk tier derives, and every tier is one of the four canonical contract tiers. (Unlike the
/// voice-cua goldens this does NOT couple a risk tier to `cua-driver`: a Quick Pass control
/// intent — pause/replay — is a ready, read-only intent with an EMPTY plan and a `none` agent.)
/// The behavioral assertions (exact actionKinds / typed text) are exercised by the TS runner
/// driving the real resolver; they are expected RED until U2/U3/U6 + the parser/risk wiring
/// land, then go green with no fixture edits.
///
/// TODO(Phase 2): Q2 (scroll-then-summarize), Q6 (two-referent terminal brief), Q7 (screenshot
/// + multimodal Codex ask) gate on units that ship after Monday — carried as `it.todo` markers
/// in `demo-quick-pass-goldens.test.ts`, not yet authored as fixtures here.
@Test func quickPassGoldensGateConsistentlyAndUseCanonicalRiskTiers() throws {
    let goldens: [VoiceGolden] = try GoldenSet.load("demo-quick-pass-goldens.json")
    #expect(!goldens.isEmpty)

    for golden in goldens {
        if let raw = golden.expected.riskLevel {
            // The approval gate the golden asserts is the one the tier derives — never the
            // model's claim — and the tier is one of the four canonical contract tiers.
            let risk = try #require(RiskLevel(rawValue: raw), "unknown risk tier \(raw) in \(golden.name)")
            #expect(risk.requiresApproval == golden.expected.requiresApproval,
                    "approval-gate drift for \(golden.name): \(raw) → \(risk.requiresApproval)")
        } else {
            // A non-ready Quick Pass golden never gates and names no agent.
            #expect(golden.expected.requiresApproval == false,
                    "non-ready quick-pass golden must not gate: \(golden.name)")
            #expect(golden.expected.targetAgent == "none",
                    "non-ready quick-pass golden has no agent: \(golden.name)")
        }
    }
}

// MARK: - head-intent LLM goldens (full resolved-intent shape)

/// A head-intent-llm-goldens.json record. Unlike the voice goldens, the LLM goldens carry the
/// FULL resolved-intent `completion`, so the ported contract types decode the real plan/
/// referent/surface payloads — this is the "fixture decode test using real TypeScript-shaped
/// JSON for action steps" gate.
private struct HeadGolden: Decodable {
    let name: String
    let transcript: String
    let candidateSurfaces: [Contracts.SurfaceSnapshot]
    let completion: Completion
    let expected: Expected

    struct Completion: Decodable {
        let referent: Contracts.SelectedReferent
        let riskLevel: RiskLevel
        let requiresApproval: Bool
        let targetAgent: Contracts.TargetAgent
        let actionPlan: Contracts.ActionPlan

        private enum CodingKeys: String, CodingKey {
            case referent
            case riskLevel = "risk_level"
            case requiresApproval = "requires_approval"
            case targetAgent = "target_agent"
            case actionPlan = "action_plan"
        }
    }

    struct Expected: Decodable {
        let status: String
        let intentType: String?
        let referentId: String?
        let targetAgent: String
        let requiresApproval: Bool
        let actionKinds: [String]
        let actionTexts: [String]

        private enum CodingKeys: String, CodingKey {
            case status
            case intentType = "intent_type"
            case referentId
            case targetAgent = "target_agent"
            case requiresApproval = "requires_approval"
            case actionKinds, actionTexts
        }
    }
}

@Test func headGoldensDecodeRealResolvedIntentPayloads() throws {
    // The decode itself is the contract test: an enum case renamed or a field reshaped TS-side
    // fails here loudly. The ActionPlan decode also enforces the approval-gate refine.
    let goldens: [HeadGolden] = try GoldenSet.load("head-intent-llm-goldens.json")
    #expect(goldens.count >= 3)
    for golden in goldens {
        #expect(!golden.completion.actionPlan.actionPlan.isEmpty, "\(golden.name) has steps")
    }
}

@Test func headGoldensProjectToTheExpectedActionPlan() throws {
    let goldens: [HeadGolden] = try GoldenSet.load("head-intent-llm-goldens.json")
    for golden in goldens {
        let steps = golden.completion.actionPlan.actionPlan
        // Voice-intent parity: the kinds and dictated text the resolver emits.
        #expect(steps.map(\.wireKind) == golden.expected.actionKinds, "actionKinds drift: \(golden.name)")
        #expect(steps.compactMap(\.typedText) == golden.expected.actionTexts, "actionTexts drift: \(golden.name)")
        #expect(golden.expected.targetAgent == "cua-driver")
    }
}

@Test func headGoldensApprovalGateIsDerivedNotTrusted() throws {
    let goldens: [HeadGolden] = try GoldenSet.load("head-intent-llm-goldens.json")
    for golden in goldens {
        let plan = golden.completion.actionPlan
        // The ActionPlan decode already refuses a plan whose requires_approval disagrees with
        // its risk tier; re-assert the derivation end-to-end against the golden's expectation.
        #expect(plan.requiresApproval == plan.riskLevel.requiresApproval, "gate not derived: \(golden.name)")
        #expect(plan.requiresApproval == golden.expected.requiresApproval, "gate drift: \(golden.name)")
    }
}

@Test func headGoldensPointingEvidenceFlowsIntoThePlanTarget() throws {
    let goldens: [HeadGolden] = try GoldenSet.load("head-intent-llm-goldens.json")
    for golden in goldens {
        let referent = golden.completion.referent
        // What the user pointed at == the referent the golden expects.
        #expect(referent.id == golden.expected.referentId, "referent drift: \(golden.name)")
        // The pointed-at surface flows into the acting step (the last step that has a target).
        let actingTargets = golden.completion.actionPlan.actionPlan.compactMap(\.targetSurfaceId)
        if let lastTarget = actingTargets.last {
            #expect(lastTarget == referent.id,
                    "acting step targets a surface other than the referent: \(golden.name)")
        }
    }
}

// MARK: - failed-action recovery goldens (KD2)

/// A failed-action-recovery-goldens.json record: an ordered sequence of CuaActionResult ticks
/// and the contract the terminal tick must satisfy.
private struct RecoveryGolden: Decodable {
    let name: String
    let note: String
    let ticks: [Contracts.CuaActionResult]
    let expected: Expected

    struct Expected: Decodable {
        let lastStatus: String
        let blockedReasonContains: String?
    }
}

@Test func failedActionRecoveryGoldensDecodeAndHonorTheResultContract() throws {
    let goldens: [RecoveryGolden] = try GoldenSet.load("failed-action-recovery-goldens.json")
    #expect(!goldens.isEmpty)

    for golden in goldens {
        let last = try #require(golden.ticks.last, "\(golden.name) has at least one tick")
        // The discriminated-union shape (succeeded|failed|blocked, optional state) decoded
        // faithfully, and the terminal disposition matches the golden.
        #expect(last.statusString == golden.expected.lastStatus, "last-status drift: \(golden.name)")

        if let needle = golden.expected.blockedReasonContains {
            // The KD2 recovery-floor blocked reason is a stable contract string.
            let reason = try #require(last.blockedReason, "\(golden.name) expected a blocked reason")
            #expect(reason.contains(needle), "blocked-reason contract drift: \(golden.name)")
        }
    }

    // RESERVED behavioral eval: the (tool,args) signature dedup that PRODUCES the blocked tick
    // lands with the step-dispatch port (driverCallForStep/callSignature) + the supervision
    // loop (PORTING.md § Porting Order 3). Until then this fixture pins the result-shape +
    // blocked-reason contract; the loop will then be asserted to reach `blocked` on a repeat.
}

// MARK: - approval-gate policy matrix (fixture-independent)

@Test func approvalGatePolicyMatrixPinsTheFourTiers() {
    // Pins the contract policy table independent of any fixture so a future edit to the gate
    // can't silently pass the goldens: read_only/reversible auto-run, mutating/external gate.
    #expect(RiskLevel.readOnly.requiresApproval == false)
    #expect(RiskLevel.reversible.requiresApproval == false)
    #expect(RiskLevel.mutating.requiresApproval == true)
    #expect(RiskLevel.destructiveExternal.requiresApproval == true)
    // The effective-risk fold gates a read+send goal as a send.
    #expect(RiskLevel.effective(of: [.readOnly, .mutating]).requiresApproval == true)
    #expect(RiskLevel.effective(of: []).requiresApproval == false)
}
