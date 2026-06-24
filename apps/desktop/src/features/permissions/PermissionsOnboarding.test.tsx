import type { CapabilityProbe, PermissionState } from "@handsoff/contracts";
import { buildReadinessReport } from "@handsoff/desktop";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { PermissionsOnboarding } from "./PermissionsOnboarding";

const report = (states: Partial<Record<string, string>>) =>
  buildReadinessReport({
    capabilities: (
      ["camera", "microphone", "speech-recognition", "accessibility", "screen-recording"] as const
    ).map(
      (id): CapabilityProbe => ({
        id,
        kind: "permission",
        state: (states[id] ?? "not-determined") as PermissionState,
      }),
    ),
  });

const noop = () => undefined;
const asyncNoop = () => Promise.resolve();

describe("PermissionsOnboarding", () => {
  it("lists every onboarding permission with its status", () => {
    render(
      <PermissionsOnboarding
        report={report({ camera: "granted" })}
        isChecking={false}
        onRequestCamera={asyncNoop}
        onRequestMedia={asyncNoop}
        onRequestScreenRecording={asyncNoop}
        onRecheck={noop}
        onRelaunch={noop}
        onOpenSettings={noop}
        onDismiss={noop}
      />,
    );
    const labels = screen
      .getAllByText(/Camera|Microphone|Speech Recognition|Accessibility|Screen Recording/)
      .filter((el) => el.className === "onboarding__step-label")
      .map((el) => el.textContent);
    expect(labels).toEqual([
      "Camera",
      "Microphone",
      "Speech Recognition",
      "Screen Recording",
      "Accessibility",
    ]);
  });

  it("requests camera then media when Grant is pressed", async () => {
    const calls: string[] = [];
    const onRequestCamera = vi.fn(() => {
      calls.push("camera");
      return Promise.resolve();
    });
    const onRequestMedia = vi.fn(() => {
      calls.push("media");
      return Promise.resolve();
    });
    const onRequestScreenRecording = vi.fn(() => {
      calls.push("screen");
      return Promise.resolve();
    });
    render(
      <PermissionsOnboarding
        report={report({})}
        isChecking={false}
        onRequestCamera={onRequestCamera}
        onRequestMedia={onRequestMedia}
        onRequestScreenRecording={onRequestScreenRecording}
        onRecheck={noop}
        onRelaunch={noop}
        onOpenSettings={noop}
        onDismiss={noop}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /grant/i }));
    await waitFor(() => expect(onRequestMedia).toHaveBeenCalled());
    // Screen recording forces a restart, so it's NOT part of the batch — its own button.
    expect(calls).toEqual(["camera", "media"]);
    expect(onRequestScreenRecording).not.toHaveBeenCalled();
  });

  it("enables screen recording from its own button (kept out of the batch)", () => {
    const onRequestScreenRecording = vi.fn(() => Promise.resolve());
    render(
      <PermissionsOnboarding
        report={report({})}
        isChecking={false}
        onRequestCamera={asyncNoop}
        onRequestMedia={asyncNoop}
        onRequestScreenRecording={onRequestScreenRecording}
        onRecheck={noop}
        onRelaunch={noop}
        onOpenSettings={noop}
        onDismiss={noop}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /enable \(needs relaunch\)/i }));
    expect(onRequestScreenRecording).toHaveBeenCalled();
  });

  it("relaunches the app so a restart-required grant takes effect", () => {
    const onRelaunch = vi.fn();
    render(
      <PermissionsOnboarding
        report={report({})}
        isChecking={false}
        onRequestCamera={asyncNoop}
        onRequestMedia={asyncNoop}
        onRequestScreenRecording={asyncNoop}
        onRecheck={noop}
        onRelaunch={onRelaunch}
        onOpenSettings={noop}
        onDismiss={noop}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /relaunch handsoff/i }));
    expect(onRelaunch).toHaveBeenCalled();
  });

  it("deep-links a manual capability to System Settings", () => {
    const onOpenSettings = vi.fn();
    render(
      <PermissionsOnboarding
        report={report({})}
        isChecking={false}
        onRequestCamera={asyncNoop}
        onRequestMedia={asyncNoop}
        onRequestScreenRecording={asyncNoop}
        onRecheck={noop}
        onRelaunch={noop}
        onOpenSettings={onOpenSettings}
        onDismiss={noop}
      />,
    );
    fireEvent.click(screen.getAllByRole("button", { name: /open system settings/i })[0]!);
    expect(onOpenSettings).toHaveBeenCalledWith("accessibility");
  });

  it("lets the user continue when only the optional Screen Recording is pending", () => {
    const onDismiss = vi.fn();
    render(
      <PermissionsOnboarding
        report={report({
          camera: "granted",
          microphone: "granted",
          "speech-recognition": "granted",
          accessibility: "granted",
          "screen-recording": "denied",
        })}
        isChecking={false}
        onRequestCamera={asyncNoop}
        onRequestMedia={asyncNoop}
        onRequestScreenRecording={asyncNoop}
        onRecheck={noop}
        onRelaunch={noop}
        onOpenSettings={noop}
        onDismiss={onDismiss}
      />,
    );
    // Screen Recording is optional (HandsOff itself never records the screen), so a
    // denied grant must NOT keep onboarding from completing.
    fireEvent.click(screen.getByRole("button", { name: /all set/i }));
    expect(onDismiss).toHaveBeenCalled();
    // ...and it should be visibly marked optional, not a hard "needs permission" blocker.
    expect(screen.getByText(/optional/i)).toBeInTheDocument();
  });

  it("shows a done state and a continue action when everything is granted", () => {
    const onDismiss = vi.fn();
    render(
      <PermissionsOnboarding
        report={report({
          camera: "granted",
          microphone: "granted",
          "speech-recognition": "granted",
          accessibility: "granted",
          "screen-recording": "granted",
        })}
        isChecking={false}
        onRequestCamera={asyncNoop}
        onRequestMedia={asyncNoop}
        onRequestScreenRecording={asyncNoop}
        onRecheck={noop}
        onRelaunch={noop}
        onOpenSettings={noop}
        onDismiss={onDismiss}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /continue/i }));
    expect(onDismiss).toHaveBeenCalled();
  });
});
