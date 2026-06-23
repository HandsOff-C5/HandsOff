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
    expect(screen.getByLabelText("Head Pointer Mode")).toBeInTheDocument();
    expect(screen.getByLabelText("Head Pointer Speed")).toBeInTheDocument();
    expect(screen.getByLabelText("Distance to Edge")).toBeInTheDocument();
  });

  it("defaults to Native and edge-mode Head Pointer settings", () => {
    renderPanel();
    expect(screen.getByLabelText("Transcription")).toHaveValue("native");
    expect(screen.getByLabelText("Head Pointer Mode")).toHaveValue("edge");
    expect(screen.getByLabelText("Head Pointer Speed")).toHaveValue(5);
    expect(screen.getByLabelText("Distance to Edge")).toHaveValue(0.12);
    expect(screen.getByRole("option", { name: "Native" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "Realtime" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "Edge" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "Relative" })).toBeInTheDocument();
    // Provider brand names are never shown to the user.
    expect(screen.queryByText(/assemblyai/i)).not.toBeInTheDocument();
  });

  it("updates the provider without dropping Head Pointer settings", () => {
    const config: LocalConfig = {
      sttProvider: "native",
      headPointer: {
        movementMode: "relative",
        speed: 7,
        distanceToEdge: 0.2,
      },
    };
    const { updateConfig } = renderPanel({ config });

    fireEvent.change(screen.getByLabelText("Transcription"), {
      target: { value: "assemblyai" },
    });
    expect(updateConfig).toHaveBeenCalledWith({ ...config, sttProvider: "assemblyai" });
  });

  it("updates Head Pointer mode without dropping the existing config", () => {
    const config: LocalConfig = {
      sttProvider: "assemblyai",
      headPointer: {
        movementMode: "edge",
        speed: 5,
        distanceToEdge: 0.12,
      },
    };
    const { updateConfig } = renderPanel({ config });

    fireEvent.change(screen.getByLabelText("Head Pointer Mode"), {
      target: { value: "relative" },
    });

    expect(updateConfig).toHaveBeenCalledWith({
      ...config,
      headPointer: { ...config.headPointer, movementMode: "relative" },
    });
  });

  it("updates Head Pointer speed without dropping the existing config", () => {
    const config: LocalConfig = {
      sttProvider: "assemblyai",
      headPointer: {
        movementMode: "edge",
        speed: 5,
        distanceToEdge: 0.12,
      },
    };
    const { updateConfig } = renderPanel({ config });

    fireEvent.change(screen.getByLabelText("Head Pointer Speed"), {
      target: { value: "8" },
    });

    expect(updateConfig).toHaveBeenCalledWith({
      ...config,
      headPointer: { ...config.headPointer, speed: 8 },
    });
  });

  it("updates distance to edge without dropping the existing config", () => {
    const config: LocalConfig = {
      sttProvider: "assemblyai",
      headPointer: {
        movementMode: "relative",
        speed: 7,
        distanceToEdge: 0.12,
      },
    };
    const { updateConfig } = renderPanel({ config });

    fireEvent.change(screen.getByLabelText("Distance to Edge"), {
      target: { value: "0.25" },
    });

    expect(updateConfig).toHaveBeenCalledWith({
      ...config,
      headPointer: { ...config.headPointer, distanceToEdge: 0.25 },
    });
  });

  it("resets when the Reset button is pressed", () => {
    const { resetConfig } = renderPanel();
    fireEvent.click(screen.getByRole("button", { name: "Reset" }));
    expect(resetConfig).toHaveBeenCalledTimes(1);
  });
});
