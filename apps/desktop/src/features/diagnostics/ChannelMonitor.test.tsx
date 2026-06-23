import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { ChannelMonitor } from "./ChannelMonitor";

const fakeStream = {} as MediaStream;

describe("ChannelMonitor", () => {
  it("renders the label and a video preview", () => {
    render(<ChannelMonitor stream={fakeStream} label="Hand cam" />);
    expect(screen.getByText("Hand cam")).toBeInTheDocument();
    expect(screen.getByTestId("channel-monitor-video")).toBeInTheDocument();
  });

  it("mirrors the preview when mirrored", () => {
    render(<ChannelMonitor stream={fakeStream} mirrored />);
    expect(screen.getByTestId("channel-monitor-video").className).toMatch(/mirror/);
  });

  it("does not mirror by default", () => {
    render(<ChannelMonitor stream={fakeStream} />);
    expect(screen.getByTestId("channel-monitor-video").className).not.toMatch(/mirror/);
  });

  it("renders the model overlay passed as children", () => {
    render(
      <ChannelMonitor stream={fakeStream}>
        <div data-testid="model-overlay" />
      </ChannelMonitor>,
    );
    expect(screen.getByTestId("model-overlay")).toBeInTheDocument();
  });

  it("marks itself active when a stream is present", () => {
    render(<ChannelMonitor stream={fakeStream} />);
    expect(screen.getByTestId("channel-monitor").dataset.active).toBe("true");
  });

  it("shows an idle state when there is no stream", () => {
    render(<ChannelMonitor stream={null} label="Eye cam" />);
    expect(screen.getByTestId("channel-monitor").dataset.active).toBe("false");
    expect(screen.getByText(/camera off/i)).toBeInTheDocument();
  });
});
