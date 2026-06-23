import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { ChannelStrip, type ChannelSample } from "./ChannelStrip";

const handLive: ChannelSample = {
  id: "hand",
  label: "Hand",
  status: "live",
  confidence: 0.9,
  detail: "→ Cursor",
  fps: 28,
};

describe("ChannelStrip", () => {
  it("renders the channel label and confidence percentage", () => {
    render(<ChannelStrip sample={handLive} />);
    expect(screen.getByText("Hand")).toBeInTheDocument();
    expect(screen.getByText("90%")).toBeInTheDocument();
  });

  it("renders the channel's current verdict/detail", () => {
    render(<ChannelStrip sample={handLive} />);
    expect(screen.getByText("→ Cursor")).toBeInTheDocument();
  });

  it("reflects the channel status on the strip", () => {
    render(<ChannelStrip sample={handLive} />);
    expect(screen.getByTestId("channel-strip").dataset.status).toBe("live");
  });

  it("fires onSolo and reflects the soloed state via aria-pressed", () => {
    const onSolo = vi.fn();
    render(<ChannelStrip sample={handLive} soloed onSolo={onSolo} />);
    const solo = screen.getByRole("button", { name: /solo/i });
    expect(solo).toHaveAttribute("aria-pressed", "true");
    fireEvent.click(solo);
    expect(onSolo).toHaveBeenCalledTimes(1);
  });

  it("fires onMute and reflects the muted state via aria-pressed", () => {
    const onMute = vi.fn();
    render(<ChannelStrip sample={handLive} muted onMute={onMute} />);
    const mute = screen.getByRole("button", { name: /mute/i });
    expect(mute).toHaveAttribute("aria-pressed", "true");
    fireEvent.click(mute);
    expect(onMute).toHaveBeenCalledTimes(1);
  });

  it("renders the input-monitor slot (camera canvas / waveform)", () => {
    render(
      <ChannelStrip sample={handLive}>
        <div data-testid="monitor" />
      </ChannelStrip>,
    );
    expect(screen.getByTestId("monitor")).toBeInTheDocument();
  });

  it("shows a no-signal channel clearly", () => {
    render(
      <ChannelStrip sample={{ id: "gaze", label: "Gaze", status: "no_signal", confidence: 0 }} />,
    );
    expect(screen.getByTestId("channel-strip").dataset.status).toBe("no_signal");
    expect(screen.getByText(/no signal/i)).toBeInTheDocument();
  });
});
