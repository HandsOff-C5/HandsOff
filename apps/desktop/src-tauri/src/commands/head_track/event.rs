use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
pub(super) struct HeadPoint {
    pub(super) x: f64,
    pub(super) y: f64,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind")]
#[serde(deny_unknown_fields)]
pub(super) enum HeadSidecarEvent {
    #[serde(rename = "start")]
    Start { ts: u64 },
    #[serde(rename = "point")]
    Point {
        x: f64,
        y: f64,
        yaw: Option<f64>,
        pitch: Option<f64>,
        confidence: f64,
        ts: u64,
    },
    #[serde(rename = "stop")]
    Stop { ts: u64 },
    #[serde(rename = "error")]
    Error { message: String, ts: u64 },
}

pub(super) fn take_stdout_lines(buffer: &mut String, chunk: &[u8]) -> Result<Vec<String>, String> {
    let text = std::str::from_utf8(chunk)
        .map_err(|error| format!("head-track stdout was not UTF-8: {error}"))?;
    buffer.push_str(text);

    let mut lines = Vec::new();
    while let Some(newline) = buffer.find('\n') {
        let line = buffer.drain(..=newline).collect::<String>();
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            lines.push(trimmed.to_string());
        }
    }
    Ok(lines)
}

pub(super) fn parse_head_event(line: &str) -> Result<HeadSidecarEvent, String> {
    let event: HeadSidecarEvent =
        serde_json::from_str(line).map_err(|error| format!("could not parse JSON: {error}"))?;
    validate_head_event(&event)?;
    Ok(event)
}

fn validate_head_event(event: &HeadSidecarEvent) -> Result<(), String> {
    match event {
        HeadSidecarEvent::Point {
            x,
            y,
            yaw,
            pitch,
            confidence,
            ..
        } => {
            if !x.is_finite() || !y.is_finite() {
                return Err("point coordinates must be finite".to_string());
            }
            if yaw.is_some_and(|value| !value.is_finite())
                || pitch.is_some_and(|value| !value.is_finite())
            {
                return Err("pose values must be finite or null".to_string());
            }
            if !(0.0..=1.0).contains(confidence) {
                return Err("confidence must be between 0 and 1".to_string());
            }
        }
        HeadSidecarEvent::Error { message, .. } if message.trim().is_empty() => {
            return Err("error message must not be empty".to_string());
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_valid_head_point_event() {
        let event = parse_head_event(
            r#"{"kind":"point","x":10,"y":20,"yaw":null,"pitch":0.1,"confidence":0.9,"ts":1803000000001}"#,
        )
        .expect("head point should parse");

        assert!(matches!(
            event,
            HeadSidecarEvent::Point {
                x: 10.0,
                y: 20.0,
                confidence: 0.9,
                ..
            }
        ));
    }

    #[test]
    fn rejects_malformed_head_events_loudly() {
        assert!(parse_head_event("not-json").is_err());
        assert!(parse_head_event(
            r#"{"kind":"point","x":10,"y":20,"yaw":null,"pitch":null,"confidence":1.2,"ts":1}"#,
        )
        .is_err());
        assert!(parse_head_event(r#"{"kind":"stop","ts":1,"extra":true}"#).is_err());
    }

    #[test]
    fn buffers_split_newline_delimited_head_events() {
        let mut buffer = String::new();
        assert!(
            take_stdout_lines(&mut buffer, br#"{"kind":"start","ts":1}"#)
                .expect("partial line should buffer")
                .is_empty()
        );

        let lines = take_stdout_lines(&mut buffer, b"\n").expect("newline should flush one line");

        assert_eq!(lines, vec![r#"{"kind":"start","ts":1}"#]);
        assert!(buffer.is_empty());
    }

    #[test]
    fn handles_coalesced_newline_delimited_head_events() {
        let mut buffer = String::new();
        let lines = take_stdout_lines(
            &mut buffer,
            br#"{"kind":"start","ts":1}
{"kind":"stop","ts":2}
"#,
        )
        .expect("coalesced lines should parse");

        assert_eq!(
            lines,
            vec![r#"{"kind":"start","ts":1}"#, r#"{"kind":"stop","ts":2}"#]
        );
        assert!(buffer.is_empty());
    }

    #[test]
    fn ignores_blank_stdout_lines_and_rejects_invalid_utf8() {
        let mut buffer = String::new();
        assert!(take_stdout_lines(&mut buffer, b"\n\n")
            .expect("blank lines are valid framing")
            .is_empty());
        assert!(take_stdout_lines(&mut buffer, &[0xff]).is_err());
    }
}
