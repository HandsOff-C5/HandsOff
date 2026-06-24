import { describe, expect, it } from "vitest";

import {
  agentBannerText,
  describeCuaAgentAction,
  formatConfidencePct,
  formatFps,
  fpsFromTimestamps,
  IDLE_SUPERVISOR_SNAPSHOT,
  modelStatus,
} from "./supervisor-signal";

describe("supervisor-signal", () => {
  it("idle snapshot has every model dark", () => {
    expect(IDLE_SUPERVISOR_SNAPSHOT.hand.point).toBeNull();
    expect(IDLE_SUPERVISOR_SNAPSHOT.gaze.point).toBeNull();
    expect(IDLE_SUPERVISOR_SNAPSHOT.voice.state).toBe("idle");
    expect(IDLE_SUPERVISOR_SNAPSHOT.agent.action).toBeNull();
    expect(IDLE_SUPERVISOR_SNAPSHOT.agent.pendingApproval).toBe(false);
  });

  describe("modelStatus", () => {
    it("is lost when the model has no fix (point null), regardless of confidence", () => {
      expect(modelStatus({ point: null, confidence: 0.9, fps: 30, lock: null })).toBe("lost");
    });
    it("is live at or above the strong threshold with a fix", () => {
      expect(modelStatus({ point: [0.5, 0.5], confidence: 0.6, fps: 30, lock: "Calc" })).toBe(
        "live",
      );
      expect(modelStatus({ point: [0.5, 0.5], confidence: 0.92, fps: 30, lock: "Calc" })).toBe(
        "live",
      );
    });
    it("is weak with a fix but low confidence", () => {
      expect(modelStatus({ point: [0.5, 0.5], confidence: 0.3, fps: 24, lock: null })).toBe("weak");
    });
  });

  describe("formatConfidencePct", () => {
    it("rounds to a whole percent", () => {
      expect(formatConfidencePct(0.92)).toBe("92%");
    });
    it("clamps into [0,100] and shows a dash for non-finite", () => {
      expect(formatConfidencePct(1.4)).toBe("100%");
      expect(formatConfidencePct(-0.2)).toBe("0%");
      expect(formatConfidencePct(Number.NaN)).toBe("—");
    });
  });

  describe("formatFps", () => {
    it("rounds a positive rate", () => {
      expect(formatFps(30.4)).toBe("30fps");
    });
    it("shows a dash when there is no rate", () => {
      expect(formatFps(0)).toBe("—");
      expect(formatFps(-5)).toBe("—");
      expect(formatFps(Number.NaN)).toBe("—");
    });
  });

  describe("fpsFromTimestamps", () => {
    it("is zero with fewer than two samples", () => {
      expect(fpsFromTimestamps([])).toBe(0);
      expect(fpsFromTimestamps([100])).toBe(0);
    });
    it("derives the rate from the sample span", () => {
      expect(fpsFromTimestamps([0, 1000])).toBe(1);
      expect(fpsFromTimestamps([0, 33, 66, 99])).toBe(30);
    });
    it("is zero when all samples share a timestamp (no span)", () => {
      expect(fpsFromTimestamps([5, 5, 5])).toBe(0);
    });
  });

  describe("agentBannerText", () => {
    it("reads Idle when the agent is doing nothing", () => {
      expect(agentBannerText({ action: null, pendingApproval: false })).toBe("Idle");
    });
    it("reads the current action in plain words", () => {
      expect(
        agentBannerText({ action: 'click "Equals" in Calculator', pendingApproval: false }),
      ).toBe('Acting: click "Equals" in Calculator');
    });
  });

  describe("describeCuaAgentAction", () => {
    it("turns each AX action into plain words", () => {
      expect(describeCuaAgentAction({ kind: "snapshot" })).toBe("look at the window");
      expect(describeCuaAgentAction({ kind: "click", elementIndex: 3 })).toBe("click element #3");
      expect(describeCuaAgentAction({ kind: "click_point", x: 12, y: 40 })).toBe(
        "click at (12, 40)",
      );
      expect(describeCuaAgentAction({ kind: "type_text", elementIndex: 1, text: "hello" })).toBe(
        'type "hello"',
      );
      expect(describeCuaAgentAction({ kind: "set_value", elementIndex: 1, value: "9" })).toBe(
        'set value to "9"',
      );
      expect(describeCuaAgentAction({ kind: "press_key", key: "Enter" })).toBe("press Enter");
      expect(describeCuaAgentAction({ kind: "press_key", key: "c", modifiers: ["cmd"] })).toBe(
        "press cmd+c",
      );
      expect(describeCuaAgentAction({ kind: "hotkey", keys: ["cmd", "v"] })).toBe("press cmd+v");
      expect(describeCuaAgentAction({ kind: "scroll", direction: "down" })).toBe("scroll down");
      expect(describeCuaAgentAction({ kind: "launch_app", appName: "Calculator" })).toBe(
        "launch Calculator",
      );
    });
  });
});
