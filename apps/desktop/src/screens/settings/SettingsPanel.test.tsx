import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { SettingsPanel } from "./SettingsPanel";

describe("SettingsPanel", () => {
  it("renders the local settings view", () => {
    render(<SettingsPanel />);
    expect(screen.getByRole("heading", { level: 2, name: "Settings" })).toBeInTheDocument();
    expect(screen.getByLabelText("STT provider")).toBeInTheDocument();
    expect(screen.getByLabelText("Demo mode")).toBeInTheDocument();
  });

  it("shows safe defaults before a native config is loaded", () => {
    render(<SettingsPanel />);
    expect(screen.getByLabelText("STT provider")).toHaveValue("assemblyai");
    expect(screen.getByLabelText("Demo mode")).not.toBeChecked();
  });

  it("lets the user change non-secret choices and reset them to defaults", () => {
    render(<SettingsPanel />);

    fireEvent.change(screen.getByLabelText("STT provider"), { target: { value: "mock" } });
    fireEvent.click(screen.getByLabelText("Demo mode"));

    expect(screen.getByLabelText("STT provider")).toHaveValue("mock");
    expect(screen.getByLabelText("Demo mode")).toBeChecked();

    fireEvent.click(screen.getByRole("button", { name: "Reset" }));

    expect(screen.getByLabelText("STT provider")).toHaveValue("assemblyai");
    expect(screen.getByLabelText("Demo mode")).not.toBeChecked();
  });
});
