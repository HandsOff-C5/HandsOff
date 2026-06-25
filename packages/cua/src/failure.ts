import type { CuaActionResult } from "@handsoff/contracts";

export type CuaFailureKind =
  | "permission"
  | "target_unavailable"
  | "canvas_limited"
  | "driver_unavailable"
  | "unknown";

export type CuaFailureRecovery = {
  kind: CuaFailureKind;
  message: string;
  nextStep: string;
};

function failureText(result: CuaActionResult): string | null {
  if (result.status === "blocked") return result.reason;
  if (result.status === "failed") return result.error;
  return null;
}

export function describeCuaFailure(result: CuaActionResult): CuaFailureRecovery | null {
  const raw = failureText(result);
  if (!raw) return null;

  const detail = raw.toLowerCase();
  if (detail.includes("accessibility")) {
    return {
      kind: "permission",
      message: "HandsOff needs Accessibility permission before it can control the selected app.",
      nextStep: "Enable Accessibility for HandsOff, then re-check readiness and retry.",
    };
  }
  if (detail.includes("screen recording") || detail.includes("screen capture")) {
    return {
      kind: "permission",
      message: "HandsOff needs Screen Recording permission before it can inspect the target.",
      nextStep: "Enable Screen Recording for HandsOff, then retry.",
    };
  }
  if (
    detail.includes("unavailable") ||
    detail.includes("disappeared") ||
    detail.includes("minimized") ||
    detail.includes("off-space") ||
    detail.includes("not on screen") ||
    detail.includes("no accessible cua window") ||
    detail.includes("no accessible target")
  ) {
    return {
      kind: "target_unavailable",
      message: "The selected window is not reachable right now.",
      nextStep: "Bring it back on screen or switch to its Space, then point and speak again.",
    };
  }
  if (
    detail.includes("canvas") ||
    detail.includes("no accessible element") ||
    detail.includes("accessibility tree")
  ) {
    return {
      kind: "canvas_limited",
      message: "The selected area does not expose accessible controls.",
      nextStep: "Use a visible native control, describe the target more clearly, or retry.",
    };
  }
  if (detail.includes("cua-driver") || detail.includes("driver")) {
    return {
      kind: "driver_unavailable",
      message: "The CUA driver is not available.",
      nextStep: "Start the driver, re-check readiness, then retry the action.",
    };
  }
  return {
    kind: "unknown",
    message: "HandsOff could not complete the CUA action.",
    nextStep: "Retry once, or clarify the target before approving again.",
  };
}

export function summarizeCuaFailure(result: CuaActionResult): string | null {
  const recovery = describeCuaFailure(result);
  return recovery ? `${recovery.message} ${recovery.nextStep}` : failureText(result);
}
