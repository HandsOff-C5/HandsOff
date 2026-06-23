import type { PermissionState, SttError, SttErrorKind, SttStreamEvent } from "@handsoff/contracts";
import { STT_ERROR_KINDS } from "@handsoff/contracts";

import { isRecord } from "../json";

// Maps native permission status integers to PermissionState.
// SFSpeechRecognizerAuthorizationStatus: 0 notDetermined, 1 denied, 2 restricted, 3 authorized.
// AVAuthorizationStatus: 0 notDetermined, 1 restricted, 2 denied, 3 authorized.
function toPermissionState(value: unknown): PermissionState | undefined {
  if (typeof value !== "number") return undefined;
  switch (value) {
    case 0:
      return "not-determined";
    case 1:
      return "denied";
    case 2:
      // Speech: restricted, AV: denied. For mic-permission errors, we treat both as "denied" since
      // the practical outcome is the same (user can't proceed).
      return "denied";
    case 3:
      return "granted";
    default:
      return "unknown";
  }
}

// Maps one raw native event — a JSON line the Rust `stt_ondevice_*` commands
// forward on the `stt://event` Tauri event — onto an `SttStreamEvent` (#31, AD2).
//
// Returns `null` for control frames ("ready", "terminated") and anything
// unrecognized; the stream treats those as no-ops. The native bridge already
// emits error kinds drawn from `STT_ERROR_KINDS`, but this validates the wire
// value and falls back to "provider-unavailable" rather than trusting it.

export interface OnDeviceEventContext {
  // When `start()` was called — used to derive a coarse latency for events the
  // native bridge does not time itself (partials carry no confidence/latency).
  readonly startMs: number;
  // Arrival time of this event.
  readonly now: number;
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
        // Native emits snake_case latency_ms; we read from both for compatibility.
        latencyMs: asNumber(
          (raw as Record<string, unknown>).latency_ms ?? raw.latencyMs,
          elapsedMs,
        ),
        receivedAt,
      };
    case "error": {
      // Native emits snake_case error_kind and permission_status; we read from both for compatibility.
      const errorKind = toErrorKind((raw as Record<string, unknown>).error_kind ?? raw.errorKind);
      const permissionStatus =
        (raw as Record<string, unknown>).permission_status ?? raw.permissionStatus;
      const permissionState = toPermissionState(permissionStatus);
      const error: SttError = {
        kind: errorKind,
        message: asString(raw.message) || "On-device recognition failed",
        ...(permissionState !== undefined && { permissionState }),
      };
      return { kind: "error", error, receivedAt };
    }
    default:
      // "ready", "terminated", or anything unknown — no transcript event.
      return null;
  }
}
