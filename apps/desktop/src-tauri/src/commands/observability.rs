use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::Mutex;

const FORBIDDEN_ATTRIBUTE_KEY_PARTS: [&str; 8] = [
    "credential",
    "password",
    "prompt",
    "raw",
    "screenshot",
    "secret",
    "token",
    "transcript",
];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ObservabilityAttributeValue {
    String(String),
    Number(f64),
    Bool(bool),
    Null,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ObservabilityBase {
    pub timestamp: String,
    pub component: String,
    pub event: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    #[serde(rename = "sessionId", skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(rename = "correlationId", skip_serializing_if = "Option::is_none")]
    pub correlation_id: Option<String>,
    #[serde(rename = "traceId", skip_serializing_if = "Option::is_none")]
    pub trace_id: Option<String>,
    #[serde(rename = "spanId", skip_serializing_if = "Option::is_none")]
    pub span_id: Option<String>,
    #[serde(default)]
    pub attributes: BTreeMap<String, ObservabilityAttributeValue>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SpanStatus {
    Ok,
    Error,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsStage {
    SessionStarted,
    ContextSelected,
    TranscriptAccepted,
    PlanApproved,
    PlanRejected,
    ActionCompleted,
    ActionFailed,
    InterruptUsed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind")]
pub enum ObservabilityRecord {
    #[serde(rename = "log", rename_all = "camelCase")]
    Log {
        #[serde(flatten)]
        base: ObservabilityBase,
        level: LogLevel,
    },
    #[serde(rename = "span", rename_all = "camelCase")]
    Span {
        #[serde(flatten)]
        base: ObservabilityBase,
        #[serde(rename = "parentSpanId", skip_serializing_if = "Option::is_none")]
        parent_span_id: Option<String>,
        #[serde(rename = "durationMs", skip_serializing_if = "Option::is_none")]
        duration_ms: Option<f64>,
        status: SpanStatus,
    },
    #[serde(rename = "metric", rename_all = "camelCase")]
    Metric {
        #[serde(flatten)]
        base: ObservabilityBase,
        name: String,
        value: f64,
        #[serde(skip_serializing_if = "Option::is_none")]
        unit: Option<String>,
    },
    #[serde(rename = "analytics", rename_all = "camelCase")]
    Analytics {
        #[serde(flatten)]
        base: ObservabilityBase,
        stage: AnalyticsStage,
    },
    #[serde(rename = "error", rename_all = "camelCase")]
    Error {
        #[serde(flatten)]
        base: ObservabilityBase,
        error_class: String,
        handled: bool,
    },
}

impl ObservabilityRecord {
    pub fn attributes_mut(&mut self) -> &mut BTreeMap<String, ObservabilityAttributeValue> {
        &mut self.base_mut().attributes
    }

    fn validate(&self) -> Result<(), String> {
        validate_base(self.base())?;
        match self {
            Self::Log { .. } | Self::Analytics { .. } => Ok(()),
            Self::Span {
                parent_span_id,
                duration_ms,
                ..
            } => {
                validate_optional_string(parent_span_id, "parentSpanId")?;
                if duration_ms.is_some_and(|value| !value.is_finite() || value < 0.0) {
                    return Err(
                        "invalid-observability-record: durationMs must be nonnegative".to_string(),
                    );
                }
                Ok(())
            }
            Self::Metric {
                name, value, unit, ..
            } => {
                validate_required_string(name, "name")?;
                validate_optional_string(unit, "unit")?;
                if !value.is_finite() {
                    return Err("invalid-observability-record: value must be finite".to_string());
                }
                Ok(())
            }
            Self::Error { error_class, .. } => {
                validate_required_string(error_class, "errorClass")?;
                Ok(())
            }
        }
    }

    fn base(&self) -> &ObservabilityBase {
        match self {
            Self::Log { base, .. }
            | Self::Span { base, .. }
            | Self::Metric { base, .. }
            | Self::Analytics { base, .. }
            | Self::Error { base, .. } => base,
        }
    }

    fn base_mut(&mut self) -> &mut ObservabilityBase {
        match self {
            Self::Log { base, .. }
            | Self::Span { base, .. }
            | Self::Metric { base, .. }
            | Self::Analytics { base, .. }
            | Self::Error { base, .. } => base,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportPolicy {
    LocalOnly,
    RemoteAllowed,
}

pub struct ObservabilitySink {
    export_policy: ExportPolicy,
    records: Mutex<Vec<ObservabilityRecord>>,
}

impl Default for ObservabilitySink {
    fn default() -> Self {
        Self::local_only()
    }
}

impl ObservabilitySink {
    pub fn local_only() -> Self {
        Self {
            export_policy: ExportPolicy::LocalOnly,
            records: Mutex::new(Vec::new()),
        }
    }

    pub fn with_remote_export_enabled() -> Self {
        Self {
            export_policy: ExportPolicy::RemoteAllowed,
            records: Mutex::new(Vec::new()),
        }
    }

    pub fn emit(&self, record: ObservabilityRecord) -> Result<(), String> {
        record.validate()?;
        self.records
            .lock()
            .map_err(|_| "observability sink is unavailable".to_string())?
            .push(record);
        Ok(())
    }

    pub fn records(&self) -> Vec<ObservabilityRecord> {
        self.records
            .lock()
            .expect("observability sink is unavailable")
            .clone()
    }

    pub fn export_policy(&self) -> ExportPolicy {
        self.export_policy
    }
}

fn validate_base(base: &ObservabilityBase) -> Result<(), String> {
    validate_required_string(&base.timestamp, "timestamp")?;
    validate_required_string(&base.component, "component")?;
    validate_required_string(&base.event, "event")?;
    validate_optional_string(&base.release, "release")?;
    validate_optional_string(&base.platform, "platform")?;
    validate_optional_string(&base.session_id, "sessionId")?;
    validate_optional_string(&base.correlation_id, "correlationId")?;
    validate_optional_string(&base.trace_id, "traceId")?;
    validate_optional_string(&base.span_id, "spanId")?;
    validate_attributes(&base.attributes)
}

fn validate_required_string(value: &str, field: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        return Err(format!(
            "invalid-observability-record: {field} must not be empty"
        ));
    }
    Ok(())
}

fn validate_optional_string(value: &Option<String>, field: &str) -> Result<(), String> {
    if value
        .as_deref()
        .is_some_and(|value| value.trim().is_empty())
    {
        return Err(format!(
            "invalid-observability-record: {field} must not be empty"
        ));
    }
    Ok(())
}

fn validate_attributes(
    attributes: &BTreeMap<String, ObservabilityAttributeValue>,
) -> Result<(), String> {
    for (key, value) in attributes {
        validate_required_string(key, "attribute key")?;
        let normalized = key.to_ascii_lowercase();
        if FORBIDDEN_ATTRIBUTE_KEY_PARTS
            .iter()
            .any(|forbidden| normalized.contains(forbidden))
        {
            return Err(
                "invalid-observability-record: attributes must not include private/raw field names"
                    .to_string(),
            );
        }
        if matches!(value, ObservabilityAttributeValue::Number(value) if !value.is_finite()) {
            return Err(
                "invalid-observability-record: attribute numbers must be finite".to_string(),
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    const TS: &str = "2026-06-27T12:00:00Z";

    fn base(event: &str) -> ObservabilityBase {
        ObservabilityBase {
            timestamp: TS.to_string(),
            component: "desktop".to_string(),
            event: event.to_string(),
            release: None,
            platform: Some("macos".to_string()),
            session_id: Some("session-1".to_string()),
            correlation_id: Some("correlation-1".to_string()),
            trace_id: Some("trace-1".to_string()),
            span_id: Some("span-1".to_string()),
            attributes: BTreeMap::from([(
                "command".to_string(),
                ObservabilityAttributeValue::String("intent_resolve".to_string()),
            )]),
        }
    }

    #[test]
    fn emits_representative_records_to_the_memory_sink() {
        let sink = ObservabilitySink::default();
        let records = vec![
            ObservabilityRecord::Log {
                base: base("intent.request"),
                level: LogLevel::Info,
            },
            ObservabilityRecord::Span {
                base: base("intent.worker"),
                parent_span_id: Some("parent-1".to_string()),
                duration_ms: Some(42.0),
                status: SpanStatus::Ok,
            },
            ObservabilityRecord::Metric {
                base: base("intent.latency"),
                name: "intent_request_ms".to_string(),
                value: 42.0,
                unit: Some("ms".to_string()),
            },
            ObservabilityRecord::Analytics {
                base: base("plan.approved"),
                stage: AnalyticsStage::PlanApproved,
            },
            ObservabilityRecord::Error {
                base: base("intent.error"),
                error_class: "provider-unavailable".to_string(),
                handled: true,
            },
        ];

        for record in &records {
            sink.emit(record.clone()).expect("record is accepted");
        }

        assert_eq!(sink.records(), records);
    }

    #[test]
    fn serializes_contract_field_names_without_null_optionals() {
        let record = ObservabilityRecord::Span {
            base: base("intent.worker"),
            parent_span_id: Some("parent-1".to_string()),
            duration_ms: Some(42.0),
            status: SpanStatus::Ok,
        };

        assert_eq!(
            serde_json::to_value(record).expect("record serializes"),
            serde_json::json!({
                "kind": "span",
                "timestamp": TS,
                "component": "desktop",
                "event": "intent.worker",
                "platform": "macos",
                "sessionId": "session-1",
                "correlationId": "correlation-1",
                "traceId": "trace-1",
                "spanId": "span-1",
                "attributes": {
                    "command": "intent_resolve"
                },
                "parentSpanId": "parent-1",
                "durationMs": 42.0,
                "status": "ok"
            })
        );
    }

    #[test]
    fn rejects_private_or_raw_attribute_keys() {
        let sink = ObservabilitySink::default();

        for key in [
            "credential",
            "password",
            "prompt",
            "raw",
            "screenshot",
            "secret",
            "token",
            "transcript",
        ] {
            let mut record = ObservabilityRecord::Log {
                base: base("intent.request"),
                level: LogLevel::Info,
            };
            record
                .attributes_mut()
                .insert(key.to_string(), ObservabilityAttributeValue::Bool(true));

            let result = sink.emit(record);

            assert!(matches!(result, Err(message) if message.contains("private/raw")));
            assert!(sink.records().is_empty());
        }
    }

    #[test]
    fn defaults_to_local_export_disabled() {
        let sink = ObservabilitySink::default();

        assert_eq!(sink.export_policy(), ExportPolicy::LocalOnly);
    }

    #[test]
    fn remote_export_requires_explicit_opt_in() {
        let sink = ObservabilitySink::with_remote_export_enabled();

        assert_eq!(sink.export_policy(), ExportPolicy::RemoteAllowed);
    }
}
