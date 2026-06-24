import type { PointingEvidence } from "@handsoff/contracts";
import { act, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { PointingOverlay, type OverlayListen } from "./PointingOverlay";
import type { FusionListen } from "./useFusionSignal";
import type { OverlaySignal } from "./overlay-signal";

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
});
