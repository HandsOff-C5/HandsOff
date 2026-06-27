//
//  Observability.swift
//  DirectorSidecar
//

import Foundation
import OSLog

enum ObservabilityRecordKind: String, Codable, Sendable {
    case log
    case span
    case metric
    case analytics
    case error
}

enum ObservabilityLogLevel: String, Codable, Sendable {
    case debug
    case info
    case warn
    case error
}

enum ObservabilitySpanStatus: String, Codable, Sendable {
    case ok
    case error
}

enum ObservabilityAnalyticsStage: String, Codable, Sendable {
    case sessionStarted = "session_started"
    case contextSelected = "context_selected"
    case transcriptAccepted = "transcript_accepted"
    case planApproved = "plan_approved"
    case planRejected = "plan_rejected"
    case actionCompleted = "action_completed"
    case actionFailed = "action_failed"
    case interruptUsed = "interrupt_used"
}

enum ObservabilityAttributeValue: Equatable, Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum ObservabilityPrivacyError: Error, Equatable, LocalizedError {
    case emptyField(String)
    case invalidTimestamp(String)
    case negativeDurationMs(Double)
    case nonFiniteNumber(String)
    case forbiddenAttributeKey(String)
    case missingKindField(String)

    var errorDescription: String? {
        switch self {
        case let .emptyField(field): return "observability field must not be empty: \(field)"
        case let .invalidTimestamp(timestamp): return "observability timestamp must be ISO-8601: \(timestamp)"
        case let .negativeDurationMs(value): return "observability span duration must be nonnegative: \(value)"
        case let .nonFiniteNumber(field): return "observability number must be finite: \(field)"
        case let .forbiddenAttributeKey(key): return "observability attributes must not include private/raw field name: \(key)"
        case let .missingKindField(field): return "observability record is missing required field: \(field)"
        }
    }
}

enum ObservabilityPrivacy {
    private static let forbiddenFragments = [
        "credential", "password", "prompt", "raw", "screenshot", "secret", "token",
        "transcript", "windowtitle", "windowcontent", "appname", "apptitle", "utterance",
        "screencontent",
    ]

    static func validateAttributes(_ attributes: [String: ObservabilityAttributeValue]) throws {
        for (key, value) in attributes {
            guard !key.isEmpty else { throw ObservabilityPrivacyError.emptyField("attributes.key") }
            if isForbiddenAttributeKey(key) {
                throw ObservabilityPrivacyError.forbiddenAttributeKey(key)
            }
            if case let .number(number) = value, !number.isFinite {
                throw ObservabilityPrivacyError.nonFiniteNumber("attributes.\(key)")
            }
        }
    }

    static func isForbiddenAttributeKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return forbiddenFragments.contains { normalized.contains($0) }
    }
}

struct ObservabilityRecord: Equatable, Sendable, Codable {
    let kind: ObservabilityRecordKind
    let timestamp: String
    let component: String
    let event: String
    let release: String?
    let platform: String?
    let sessionId: String?
    let correlationId: String?
    let traceId: String?
    let spanId: String?
    let attributes: [String: ObservabilityAttributeValue]
    let level: ObservabilityLogLevel?
    let parentSpanId: String?
    let durationMs: Double?
    let status: ObservabilitySpanStatus?
    let name: String?
    let value: Double?
    let unit: String?
    let stage: ObservabilityAnalyticsStage?
    let errorClass: String?
    let handled: Bool?

    init(
        kind: ObservabilityRecordKind,
        timestamp: String,
        component: String,
        event: String,
        release: String? = nil,
        platform: String? = nil,
        sessionId: String? = nil,
        correlationId: String? = nil,
        traceId: String? = nil,
        spanId: String? = nil,
        attributes: [String: ObservabilityAttributeValue] = [:],
        level: ObservabilityLogLevel? = nil,
        parentSpanId: String? = nil,
        durationMs: Double? = nil,
        status: ObservabilitySpanStatus? = nil,
        name: String? = nil,
        value: Double? = nil,
        unit: String? = nil,
        stage: ObservabilityAnalyticsStage? = nil,
        errorClass: String? = nil,
        handled: Bool? = nil
    ) throws {
        try Self.validateBase(
            timestamp: timestamp,
            component: component,
            event: event,
            release: release,
            platform: platform,
            sessionId: sessionId,
            correlationId: correlationId,
            traceId: traceId,
            spanId: spanId
        )
        try ObservabilityPrivacy.validateAttributes(attributes)
        if let durationMs, !durationMs.isFinite { throw ObservabilityPrivacyError.nonFiniteNumber("durationMs") }
        if let durationMs, durationMs < 0 { throw ObservabilityPrivacyError.negativeDurationMs(durationMs) }
        try Self.validateKind(
            kind,
            level: level,
            status: status,
            name: name,
            value: value,
            unit: unit,
            stage: stage,
            errorClass: errorClass,
            handled: handled
        )

        self.kind = kind
        self.timestamp = timestamp
        self.component = component
        self.event = event
        self.release = release
        self.platform = platform
        self.sessionId = sessionId
        self.correlationId = correlationId
        self.traceId = traceId
        self.spanId = spanId
        self.attributes = attributes
        self.level = level
        self.parentSpanId = parentSpanId
        self.durationMs = durationMs
        self.status = status
        self.name = name
        self.value = value
        self.unit = unit
        self.stage = stage
        self.errorClass = errorClass
        self.handled = handled
    }

    private static func validateKind(
        _ kind: ObservabilityRecordKind,
        level: ObservabilityLogLevel?,
        status: ObservabilitySpanStatus?,
        name: String?,
        value: Double?,
        unit: String?,
        stage: ObservabilityAnalyticsStage?,
        errorClass: String?,
        handled: Bool?
    ) throws {
        switch kind {
        case .log:
            guard level != nil else { throw ObservabilityPrivacyError.missingKindField("level") }
        case .span:
            guard status != nil else { throw ObservabilityPrivacyError.missingKindField("status") }
        case .metric:
            try validateRequired(name, "name")
            guard let value else { throw ObservabilityPrivacyError.missingKindField("value") }
            guard value.isFinite else { throw ObservabilityPrivacyError.nonFiniteNumber("value") }
            try validateOptional(unit, "unit")
        case .analytics:
            guard stage != nil else { throw ObservabilityPrivacyError.missingKindField("stage") }
        case .error:
            try validateRequired(errorClass, "errorClass")
            guard handled != nil else { throw ObservabilityPrivacyError.missingKindField("handled") }
        }
    }

    private static func validateBase(
        timestamp: String,
        component: String,
        event: String,
        release: String?,
        platform: String?,
        sessionId: String?,
        correlationId: String?,
        traceId: String?,
        spanId: String?
    ) throws {
        guard isISODateTime(timestamp) else { throw ObservabilityPrivacyError.invalidTimestamp(timestamp) }
        try validateRequired(component, "component")
        try validateRequired(event, "event")
        try validateOptional(release, "release")
        try validateOptional(platform, "platform")
        try validateOptional(sessionId, "sessionId")
        try validateOptional(correlationId, "correlationId")
        try validateOptional(traceId, "traceId")
        try validateOptional(spanId, "spanId")
    }

    private static func validateRequired(_ value: String?, _ field: String) throws {
        guard let value, !value.isEmpty else { throw ObservabilityPrivacyError.emptyField(field) }
    }

    private static func validateOptional(_ value: String?, _ field: String) throws {
        if let value, value.isEmpty { throw ObservabilityPrivacyError.emptyField(field) }
    }

    static func isISODateTime(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value) != nil
    }
}

enum ObservabilityExport: String, Codable, Sendable {
    case local
    case remote
}

struct ObservabilityExportPolicy: Equatable, Sendable, Codable {
    let remoteRequested: Bool
    let consentGranted: Bool

    static let localDefault = ObservabilityExportPolicy(
        remoteRequested: false,
        consentGranted: false
    )

    static func remote(consentGranted: Bool) -> ObservabilityExportPolicy {
        ObservabilityExportPolicy(remoteRequested: true, consentGranted: consentGranted)
    }

    var remoteExportAllowed: Bool {
        remoteRequested && consentGranted
    }
}

struct ObservabilityEnvelope: Equatable, Sendable, Codable {
    let schemaVersion: String
    let generatedAt: String
    let export: ObservabilityExport
    let remoteExportAllowed: Bool
    let record: ObservabilityRecord

    init(
        record: ObservabilityRecord,
        policy: ObservabilityExportPolicy = .localDefault,
        generatedAt: String
    ) throws {
        guard ObservabilityRecord.isISODateTime(generatedAt) else {
            throw ObservabilityPrivacyError.invalidTimestamp(generatedAt)
        }
        self.schemaVersion = "observability.v1"
        self.generatedAt = generatedAt
        self.export = policy.remoteExportAllowed ? .remote : .local
        self.remoteExportAllowed = policy.remoteExportAllowed
        self.record = record
    }

    static func crash(
        timestamp: String,
        component: String,
        errorClass: String,
        sessionId: String? = nil,
        attributes: [String: ObservabilityAttributeValue] = [:],
        policy: ObservabilityExportPolicy = .localDefault
    ) throws -> ObservabilityEnvelope {
        let record = try ObservabilityRecord(
            kind: .error,
            timestamp: timestamp,
            component: component,
            event: "crash",
            sessionId: sessionId,
            attributes: attributes,
            errorClass: errorClass,
            handled: false
        )
        return try ObservabilityEnvelope(record: record, policy: policy, generatedAt: timestamp)
    }
}

protocol ObservabilitySink: Sendable {
    func emit(_ envelope: ObservabilityEnvelope) async throws
}

struct ObservabilityOSLogSink: ObservabilitySink {
    private let logger: Logger

    init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "DirectorSidecar",
        category: String = "observability"
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    func emit(_ envelope: ObservabilityEnvelope) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard let line = String(data: data, encoding: .utf8) else { return }
        logger.info("\(line, privacy: .private)")
    }
}

actor ObservabilityMemorySink: ObservabilitySink {
    private let limit: Int
    private var emitted: [ObservabilityEnvelope] = []

    init(limit: Int = 256) {
        self.limit = max(1, limit)
    }

    func emit(_ envelope: ObservabilityEnvelope) async throws {
        emitted.append(envelope)
        if emitted.count > limit {
            emitted.removeFirst(emitted.count - limit)
        }
    }

    func records() -> [ObservabilityRecord] {
        emitted.map(\.record)
    }

    func envelopes() -> [ObservabilityEnvelope] {
        emitted
    }
}

struct ObservabilityClient: Sendable {
    let component: String
    let sink: any ObservabilitySink
    let policy: ObservabilityExportPolicy
    let release: String?
    let platform: String?
    let clock: @Sendable () -> String

    init(
        component: String,
        sink: any ObservabilitySink = ObservabilityMemorySink(),
        policy: ObservabilityExportPolicy = .localDefault,
        release: String? = nil,
        platform: String? = "macos",
        clock: @escaping @Sendable () -> String = { ObservabilityClient.timestamp() }
    ) {
        self.component = component
        self.sink = sink
        self.policy = policy
        self.release = release
        self.platform = platform
        self.clock = clock
    }

    func log(
        _ level: ObservabilityLogLevel,
        event: String,
        sessionId: String? = nil,
        correlationId: String? = nil,
        attributes: [String: ObservabilityAttributeValue] = [:]
    ) async throws {
        try await emit(
            kind: .log, event: event, sessionId: sessionId, correlationId: correlationId,
            attributes: attributes, level: level)
    }

    func span(
        event: String,
        sessionId: String? = nil,
        correlationId: String? = nil,
        traceId: String? = nil,
        spanId: String? = nil,
        parentSpanId: String? = nil,
        durationMs: Double? = nil,
        status: ObservabilitySpanStatus = .ok,
        attributes: [String: ObservabilityAttributeValue] = [:]
    ) async throws {
        try await emit(
            kind: .span,
            event: event,
            sessionId: sessionId,
            correlationId: correlationId,
            traceId: traceId,
            spanId: spanId,
            attributes: attributes,
            parentSpanId: parentSpanId,
            durationMs: durationMs,
            status: status
        )
    }

    func metric(
        name: String,
        value: Double,
        unit: String? = nil,
        event: String,
        sessionId: String? = nil,
        correlationId: String? = nil,
        attributes: [String: ObservabilityAttributeValue] = [:]
    ) async throws {
        try await emit(
            kind: .metric,
            event: event,
            sessionId: sessionId,
            correlationId: correlationId,
            attributes: attributes,
            name: name,
            value: value,
            unit: unit
        )
    }

    func analytics(
        stage: ObservabilityAnalyticsStage,
        event: String,
        sessionId: String? = nil,
        correlationId: String? = nil,
        attributes: [String: ObservabilityAttributeValue] = [:]
    ) async throws {
        try await emit(
            kind: .analytics, event: event, sessionId: sessionId, correlationId: correlationId,
            attributes: attributes, stage: stage)
    }

    func error(
        event: String,
        errorClass: String,
        handled: Bool,
        sessionId: String? = nil,
        correlationId: String? = nil,
        attributes: [String: ObservabilityAttributeValue] = [:]
    ) async throws {
        try await emit(
            kind: .error,
            event: event,
            sessionId: sessionId,
            correlationId: correlationId,
            attributes: attributes,
            errorClass: errorClass,
            handled: handled
        )
    }

    private func emit(
        kind: ObservabilityRecordKind,
        event: String,
        sessionId: String? = nil,
        correlationId: String? = nil,
        traceId: String? = nil,
        spanId: String? = nil,
        attributes: [String: ObservabilityAttributeValue] = [:],
        level: ObservabilityLogLevel? = nil,
        parentSpanId: String? = nil,
        durationMs: Double? = nil,
        status: ObservabilitySpanStatus? = nil,
        name: String? = nil,
        value: Double? = nil,
        unit: String? = nil,
        stage: ObservabilityAnalyticsStage? = nil,
        errorClass: String? = nil,
        handled: Bool? = nil
    ) async throws {
        let now = clock()
        let record = try ObservabilityRecord(
            kind: kind,
            timestamp: now,
            component: component,
            event: event,
            release: release,
            platform: platform,
            sessionId: sessionId,
            correlationId: correlationId,
            traceId: traceId,
            spanId: spanId,
            attributes: attributes,
            level: level,
            parentSpanId: parentSpanId,
            durationMs: durationMs,
            status: status,
            name: name,
            value: value,
            unit: unit,
            stage: stage,
            errorClass: errorClass,
            handled: handled
        )
        try await sink.emit(try ObservabilityEnvelope(record: record, policy: policy, generatedAt: now))
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func bundleRelease(_ bundle: Bundle = .main) -> String? {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (.some(version), .some(build)): return "\(version)+\(build)"
        case let (.some(version), .none): return version
        case let (.none, .some(build)): return build
        case (.none, .none): return nil
        }
    }
}
