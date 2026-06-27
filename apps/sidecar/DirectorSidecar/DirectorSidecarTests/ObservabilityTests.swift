//
//  ObservabilityTests.swift
//  DirectorSidecarTests
//
//  Director observability contract tests: safe structured records, local/test sink,
//  export gating, and privacy guardrails for the native Swift slice.
//

import Foundation
import Testing
@testable import DirectorSidecar

private let fixedObservabilityTime = "2026-06-27T12:00:00.000Z"

@Test func memorySinkStoresExactStructuredRecords() async throws {
    let sink = ObservabilityMemorySink()
    let observability = ObservabilityClient(
        component: "director.loop",
        sink: sink,
        clock: { fixedObservabilityTime }
    )

    try await observability.log(
        .info,
        event: "loop.ready",
        sessionId: "session-1",
        attributes: ["mode": .string("local"), "ready": .bool(true)]
    )
    try await observability.span(
        event: "resolver.resolve",
        traceId: "trace-1",
        spanId: "span-1",
        durationMs: 12,
        status: .ok,
        attributes: ["tool_count": .number(3)]
    )
    try await observability.metric(
        name: "resolver_latency_ms",
        value: 42,
        unit: "ms",
        event: "resolver.latency"
    )
    try await observability.analytics(
        stage: .sessionStarted,
        event: "session.started",
        sessionId: "session-1"
    )
    try await observability.error(
        event: "driver.call.failed",
        errorClass: "CuaDriverError",
        handled: true,
        sessionId: "session-1"
    )

    let expected = [
        try ObservabilityRecord(
            kind: .log,
            timestamp: fixedObservabilityTime,
            component: "director.loop",
            event: "loop.ready",
            sessionId: "session-1",
            attributes: ["mode": .string("local"), "ready": .bool(true)],
            level: .info
        ),
        try ObservabilityRecord(
            kind: .span,
            timestamp: fixedObservabilityTime,
            component: "director.loop",
            event: "resolver.resolve",
            traceId: "trace-1",
            spanId: "span-1",
            attributes: ["tool_count": .number(3)],
            durationMs: 12,
            status: .ok
        ),
        try ObservabilityRecord(
            kind: .metric,
            timestamp: fixedObservabilityTime,
            component: "director.loop",
            event: "resolver.latency",
            name: "resolver_latency_ms",
            value: 42,
            unit: "ms"
        ),
        try ObservabilityRecord(
            kind: .analytics,
            timestamp: fixedObservabilityTime,
            component: "director.loop",
            event: "session.started",
            sessionId: "session-1",
            stage: .sessionStarted
        ),
        try ObservabilityRecord(
            kind: .error,
            timestamp: fixedObservabilityTime,
            component: "director.loop",
            event: "driver.call.failed",
            sessionId: "session-1",
            errorClass: "CuaDriverError",
            handled: true
        ),
    ]

    #expect(await sink.records() == expected)
}

@Test func rejectsPrivateRawAndWindowContentAttributeKeys() {
    for key in [
        "rawTranscript",
        "prompt",
        "screenshot_png_b64",
        "apiToken",
        "secretValue",
        "windowTitle",
        "appName",
    ] {
        #expect(throws: ObservabilityPrivacyError.forbiddenAttributeKey(key)) {
            _ = try ObservabilityRecord(
                kind: .log,
                timestamp: fixedObservabilityTime,
                component: "director.loop",
                event: "unsafe",
                attributes: [key: .string("private")],
                level: .info
            )
        }
    }
}

@Test func exportPolicyDefaultsToLocalOnlyAndRequiresConsentForRemote() throws {
    let record = try ObservabilityRecord(
        kind: .metric,
        timestamp: fixedObservabilityTime,
        component: "director.loop",
        event: "resolver.latency",
        name: "resolver_latency_ms",
        value: 42,
        unit: "ms"
    )

    let local = try ObservabilityEnvelope(record: record, policy: .localDefault, generatedAt: fixedObservabilityTime)
    #expect(local.export == .local)
    #expect(!local.remoteExportAllowed)

    #expect(!ObservabilityExportPolicy.remote(consentGranted: false).remoteExportAllowed)
    #expect(ObservabilityExportPolicy.remote(consentGranted: true).remoteExportAllowed)
}

@Test func crashEnvelopeUsesErrorRecordWithoutRawDetails() throws {
    let envelope = try ObservabilityEnvelope.crash(
        timestamp: fixedObservabilityTime,
        component: "director.loop",
        errorClass: "NSException",
        sessionId: "session-1",
        attributes: ["handled_by": .string("crash-reporter")]
    )

    #expect(envelope.record.kind == .error)
    #expect(envelope.record.event == "crash")
    #expect(envelope.record.errorClass == "NSException")
    #expect(envelope.record.handled == false)
    #expect(envelope.record.attributes == ["handled_by": .string("crash-reporter")])

    #expect(throws: ObservabilityPrivacyError.forbiddenAttributeKey("rawCrashLog")) {
        _ = try ObservabilityEnvelope.crash(
            timestamp: fixedObservabilityTime,
            component: "director.loop",
            errorClass: "NSException",
            attributes: ["rawCrashLog": .string("private")]
        )
    }
}
