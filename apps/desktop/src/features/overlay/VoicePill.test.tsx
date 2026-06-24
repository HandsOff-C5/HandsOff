import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { VoicePill } from "./VoicePill";

describe("VoicePill", () => {
  it("shows the engagement label and the last words heard", () => {
    render(<VoicePill voice={{ state: "listening", transcript: "press seven plus five" }} />);
    expect(screen.getByText("Listening…")).toBeInTheDocument();
    expect(screen.getByText("press seven plus five")).toBeInTheDocument();
    expect(screen.getByTestId("voice-pill")).toHaveAttribute("data-voice-state", "listening");
  });

  it("omits the transcript line when there are no words yet", () => {
    render(<VoicePill voice={{ state: "idle", transcript: null }} />);
    expect(screen.getByText("Ready")).toBeInTheDocument();
    expect(screen.queryByTestId("voice-pill-transcript")).toBeNull();
  });
});
