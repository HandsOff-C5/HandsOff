import { DEFAULT_LOCAL_CONFIG, type LocalConfig } from "@handsoff/contracts";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { SettingsPanel } from "./SettingsPanel";
import type { LocalConfigStatus } from "./useLocalConfig";

function renderPanel(overrides: Partial<Parameters<typeof SettingsPanel>[0]> = {}) {
  const props = {
    config: DEFAULT_LOCAL_CONFIG as LocalConfig,
    status: "ready" as LocalConfigStatus,
    updateConfig: vi.fn(),
    resetConfig: vi.fn(),
    ...overrides,
  };
  render(<SettingsPanel {...props} />);
  return props;
}

describe("SettingsPanel", () => {
  it("renders the transcription selector under Settings", () => {
    renderPanel();
    expect(screen.getByRole("heading", { level: 2, name: "Settings" })).toBeInTheDocument();
    expect(screen.getByLabelText("Transcription")).toBeInTheDocument();
  });

  it("defaults to Native and offers Realtime without naming the provider", () => {
    renderPanel();
    expect(screen.getByLabelText("Transcription")).toHaveValue("native");
    expect(screen.getByRole("option", { name: "Native" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "Realtime" })).toBeInTheDocument();
    // Provider brand names are never shown to the user.
    expect(screen.queryByText(/assemblyai/i)).not.toBeInTheDocument();
  });

  it("updates the provider when the selection changes", () => {
    const { updateConfig } = renderPanel();
    fireEvent.change(screen.getByLabelText("Transcription"), {
      target: { value: "assemblyai" },
    });
    expect(updateConfig).toHaveBeenCalledWith({ sttProvider: "assemblyai" });
  });

  it("resets when the Reset button is pressed", () => {
    const { resetConfig } = renderPanel();
    fireEvent.click(screen.getByRole("button", { name: "Reset" }));
    expect(resetConfig).toHaveBeenCalledTimes(1);
  });
});
