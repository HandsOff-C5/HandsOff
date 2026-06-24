import type { PointingEvidence } from "@handsoff/contracts";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { PointingOverlay, type OverlayListen, type SupervisorListen } from "./PointingOverlay";
import type { FusionListen } from "./useFusionSignal";
import type { OverlaySignal } from "./overlay-signal";
import type { SupervisorSnapshot } from "./supervisor-signal";

function signal(overrides: Partial<OverlaySignal> = {}): OverlaySignal {
  return { point: [0.5, 0.5], confidence: 1, targetLabel: null, voiceState: "idle", ...overrides };
}

describe("PointingOverlay", () => {
  it("renders the marker at the live point", () => {
    render(<PointingOverlay signal={signal({ point: [0.25, 0.75] })} />);
    const marker = screen.getByTestId("overlay-marker");
    expect(marker.style.left).toBe("25%");
    expect(marker.style.top).toBe("75%");
  });

  it("hides the marker when there is no point", () => {
    render(<PointingOverlay signal={signal({ point: null })} />);
    expect(screen.queryByTestId("overlay-marker")).not.toBeInTheDocument();
  });

  it("shows the locked target label", () => {
    render(<PointingOverlay signal={signal({ targetLabel: "Cursor — main.ts" })} />);
    expect(screen.getByText("Cursor — main.ts")).toBeInTheDocument();
  });

  it("renders the voice-state indicator", () => {
    const { rerender } = render(<PointingOverlay signal={signal({ voiceState: "listening" })} />);
    expect(screen.getByText("Listening…")).toBeInTheDocument();
    rerender(<PointingOverlay signal={signal({ voiceState: "acting" })} />);
    expect(screen.getByText("Acting…")).toBeInTheDocument();
  });

  it("tracks pointer and voice updates from the injected listener", () => {
    let pushPointer:
      | ((u: {
          point: [number, number] | null;
          confidence: number;
          targetLabel: string | null;
        }) => void)
      | undefined;
    let pushVoice: ((v: OverlaySignal["voiceState"]) => void) | undefined;
    const listen: OverlayListen = (onPointer, onVoice) => {
      pushPointer = onPointer;
      pushVoice = onVoice;
      return () => {};
    };

    render(<PointingOverlay listen={listen} />);
    // Starts idle: no marker, "Ready".
    expect(screen.queryByTestId("overlay-marker")).not.toBeInTheDocument();
    expect(screen.getByText("Ready")).toBeInTheDocument();

    act(() => pushPointer?.({ point: [0.1, 0.2], confidence: 0.9, targetLabel: "Slack" }));
    act(() => pushVoice?.("acting"));

    expect(screen.getByTestId("overlay-marker").style.left).toBe("10%");
    expect(screen.getByText("Slack")).toBeInTheDocument();
    expect(screen.getByText("Acting…")).toBeInTheDocument();
  });

  it("renders the live per-model fusion HUD from the injected fusion listener", () => {
    let pushFusion: ((evidence: PointingEvidence[]) => void) | undefined;
    const fusionListen: FusionListen = (onEvidence) => {
      pushFusion = onEvidence;
      return () => {};
    };
    const surface = {
      id: "win-cursor",
      title: "main.ts",
      app: "Cursor",
      availability: "available" as const,
      accessStatus: "accessible" as const,
    };

    render(<PointingOverlay fusionListen={fusionListen} />);
    // Idle until evidence arrives.
    expect(screen.getByText("No signal")).toBeInTheDocument();

    act(() =>
      pushFusion?.([
        { source: "gesture", confidence: 0.9, strategy: "wrist-ray", surface },
        { source: "head", confidence: 0.6, strategy: "head-pose", surface },
      ]),
    );

    // The fused decision + per-model meters now render on the overlay.
    expect(screen.getByLabelText("Fusion HUD")).toBeInTheDocument();
    expect(screen.getByTestId("fusion-decision")).toBeInTheDocument();
    expect(screen.getByTestId("fusion-target")).toBeInTheDocument();
  });

  describe("supervisor HUD (overlay-as-UI)", () => {
    const snapshot: SupervisorSnapshot = {
      hand: { point: [0.3, 0.4], confidence: 0.92, fps: 30, lock: "Calculator" },
      gaze: { point: [0.6, 0.2], confidence: 0.61, fps: 24, lock: "Mail" },
      voice: { state: "listening", transcript: "press seven" },
      agent: { action: "click Equals", pendingApproval: true },
    };

    it("paints two desktop cursors, the perception panel, voice pill, and agent banner", () => {
      render(<PointingOverlay supervisor={snapshot} />);
      expect(screen.getByTestId("cursor-hand").style.left).toBe("30%");
      expect(screen.getByTestId("cursor-gaze").style.left).toBe("60%");
      expect(screen.getByTestId("perception-row-hand")).toBeInTheDocument();
      expect(screen.getByTestId("perception-row-gaze")).toBeInTheDocument();
      expect(screen.getByTestId("voice-pill")).toHaveAttribute("data-voice-state", "listening");
      expect(screen.getByText("Acting: click Equals")).toBeInTheDocument();
    });

    it("routes the on-overlay approve/deny chip to the engine callbacks", () => {
      const onApprove = vi.fn();
      const onDeny = vi.fn();
      render(<PointingOverlay supervisor={snapshot} onApprove={onApprove} onDeny={onDeny} />);
      fireEvent.click(screen.getByRole("button", { name: /approve/i }));
      fireEvent.click(screen.getByRole("button", { name: /deny/i }));
      expect(onApprove).toHaveBeenCalledTimes(1);
      expect(onDeny).toHaveBeenCalledTimes(1);
    });

    it("subscribes to the live supervisor listener", () => {
      let push: ((s: SupervisorSnapshot) => void) | undefined;
      const supervisorListen: SupervisorListen = (onSnapshot) => {
        push = onSnapshot;
        return () => {};
      };
      render(<PointingOverlay supervisorListen={supervisorListen} />);
      // Nothing supervisor-shaped until the first snapshot arrives.
      expect(screen.queryByTestId("perception-row-hand")).not.toBeInTheDocument();
      act(() => push?.(snapshot));
      expect(screen.getByTestId("perception-row-hand")).toBeInTheDocument();
      expect(screen.getByTestId("cursor-gaze")).toBeInTheDocument();
    });

    it("shows the calibration gate instead of the HUD while calibration is active", () => {
      const calibration = {
        active: true as const,
        phase: "hand" as const,
        step: 1,
        totalSteps: 2,
        targets: Array.from({ length: 9 }, () => [0.1, 0.1] as [number, number]),
        currentIndex: 0,
        dwellProgress: 0,
        quality: null,
      };
      render(<PointingOverlay supervisor={snapshot} calibration={calibration} />);
      // The gate wins over the HUD.
      expect(screen.getByText(/step 1 of 2/i)).toBeInTheDocument();
      expect(screen.getAllByTestId("calib-dot")).toHaveLength(9);
      expect(screen.queryByTestId("perception-row-hand")).not.toBeInTheDocument();
    });
  });
});
