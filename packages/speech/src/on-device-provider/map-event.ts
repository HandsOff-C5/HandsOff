import type { SttError, SttErrorKind, SttStreamEvent } from "@handsoff/contracts";
import { STT_ERROR_KINDS } from "@handsoff/contracts";

// Maps one raw sidecar event — a JSON line the Rust `stt_ondevice_*` commands
// forward on the `stt://event` Tauri event — onto an `SttStreamEvent` (#31, AD2).
//
// Returns `null` for control frames ("ready", "terminated") and anything
// unrecognized; the stream treats those as no-ops. The native sidecar already
// emits error kinds drawn from `STT_ERROR_KINDS`, but this validates the wire
// value and falls back to "provider-unavailable" rather than trusting it.

export interface OnDeviceEventContext {
  // When `start()` was called — used to derive a coarse latency for events the
  // sidecar does not time itself (partials carry no confidence/latency).
  readonly startMs: number;
  // Arrival time of this event.
  readonly now: number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function asNumber(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function toErrorKind(value: unknown): SttErrorKind {
  return STT_ERROR_KINDS.includes(value as SttErrorKind)
    ? (value as SttErrorKind)
    : "provider-unavailable";
}

export function mapOnDeviceEvent(
  raw: unknown,
  context: OnDeviceEventContext,
): SttStreamEvent | null {
  if (!isRecord(raw) || typeof raw.kind !== "string") return null;

  const receivedAt = context.now;
  const elapsedMs = Math.max(0, context.now - context.startMs);

  switch (raw.kind) {
    case "partial":
      return {
        kind: "partial",
        text: asString(raw.text),
        confidence: 0,
        latencyMs: elapsedMs,
        receivedAt,
      };
    case "final":
      return {
        kind: "final",
        text: asString(raw.text),
        confidence: asNumber(raw.confidence, 0),
        latencyMs: asNumber(raw.latencyMs, elapsedMs),
        receivedAt,
      };
    case "error": {
      const error: SttError = {
        kind: toErrorKind(raw.errorKind),
        message: asString(raw.message) || "On-device recognition failed",
      };
      return { kind: "error", error, receivedAt };
    }
    default:
      // "ready", "terminated", or anything unknown — no transcript event.
      return null;
  }
}
