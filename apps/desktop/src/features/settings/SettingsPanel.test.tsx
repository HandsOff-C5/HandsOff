import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { SettingsPanel } from "./SettingsPanel";

describe("SettingsPanel", () => {
  it("renders the local settings view", () => {
    render(<SettingsPanel />);
    expect(screen.getByRole("heading", { level: 2, name: "Settings" })).toBeInTheDocument();
    expect(screen.getByLabelText("STT provider")).toBeInTheDocument();
  });

  it("shows the default provider before a native config is loaded", () => {
    render(<SettingsPanel />);
    expect(screen.getByLabelText("STT provider")).toHaveValue("assemblyai");
  });

  it("keeps the default provider after a reset", () => {
    render(<SettingsPanel />);

    fireEvent.click(screen.getByRole("button", { name: "Reset" }));

    expect(screen.getByLabelText("STT provider")).toHaveValue("assemblyai");
  });
});
