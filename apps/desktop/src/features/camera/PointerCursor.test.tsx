import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { PointerCursor } from "./PointerCursor";

// Presentational cursor for the smoothed pointing position (A1.3). Tested directly with
// props (no camera/frame loop), like LandmarkOverlay — the live wiring is demo-verified.
const BOUNDS = { x: 0, y: 0, w: 1920, h: 1080 };

describe("PointerCursor", () => {
  it("renders nothing when there is no point", () => {
    render(<PointerCursor point={null} bounds={BOUNDS} mirrored={false} confidence={1} />);
    expect(screen.queryByTestId("pointer-cursor")).toBeNull();
  });

  it("positions the cursor at the normalized point within the bounds", () => {
    render(<PointerCursor point={[960, 540]} bounds={BOUNDS} mirrored={false} confidence={1} />);
    const cursor = screen.getByTestId("pointer-cursor");
    expect(cursor.style.left).toBe("50%");
    expect(cursor.style.top).toBe("50%");
  });

  it("mirrors the x position for selfie-view (camera mirrored)", () => {
    // 480/1920 = 0.25 → mirrored → 0.75; y is unaffected by mirroring.
    render(<PointerCursor point={[480, 540]} bounds={BOUNDS} mirrored={true} confidence={1} />);
    const cursor = screen.getByTestId("pointer-cursor");
    expect(cursor.style.left).toBe("75%");
    expect(cursor.style.top).toBe("50%");
  });

  it("scales the glow with confidence — bright + wide when sure, dim + tight when unsure", () => {
    const { rerender } = render(
      <PointerCursor point={[960, 540]} bounds={BOUNDS} mirrored={false} confidence={1} />,
    );
    const sure = screen.getByTestId("pointer-cursor");
    expect(sure.style.opacity).toBe("1");
    expect(sure.style.boxShadow).toContain("16px");

    rerender(<PointerCursor point={[960, 540]} bounds={BOUNDS} mirrored={false} confidence={0} />);
    const unsure = screen.getByTestId("pointer-cursor");
    expect(unsure.style.opacity).toBe("0.35");
    expect(unsure.style.boxShadow).toContain("4px");
  });
});
