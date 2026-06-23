import { APP_NAME, type CapabilityProbe } from "@handsoff/contracts";
import { buildReadinessReport } from "@handsoff/desktop";
import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { PermissionsPanel } from "./PermissionsPanel";

const report = (capabilities: CapabilityProbe[]) => buildReadinessReport({ capabilities });

// Both TCC grants present → HandsOff can see and act.
const ALL_GRANTED = report([
  { id: "camera", kind: "permission", state: "granted" },
  { id: "accessibility", kind: "permission", state: "granted" },
  { id: "screen-recording", kind: "permission", state: "granted" },
]);

// Accessibility denied, Screen Recording still not granted.
const ACCESSIBILITY_DENIED = report([
  { id: "camera", kind: "permission", state: "granted" },
  { id: "accessibility", kind: "permission", state: "denied" },
  { id: "screen-recording", kind: "permission", state: "granted" },
]);

const SCREEN_RECORDING_DENIED = report([
  { id: "camera", kind: "permission", state: "granted" },
  { id: "accessibility", kind: "permission", state: "granted" },
  { id: "screen-recording", kind: "permission", state: "denied" },
]);

const CAMERA_DENIED = report([
  { id: "camera", kind: "permission", state: "denied" },
  { id: "accessibility", kind: "permission", state: "granted" },
  { id: "screen-recording", kind: "permission", state: "granted" },
]);

const noop = () => {};

describe("PermissionsPanel", () => {
  it("renders under the Permissions heading", () => {
    render(<PermissionsPanel report={ALL_GRANTED} isChecking={false} onRecheck={noop} />);
    expect(screen.getByRole("heading", { level: 2, name: "Permissions" })).toBeInTheDocument();
  });

  it("shows targeted Accessibility guidance when it is missing", () => {
    render(<PermissionsPanel report={ACCESSIBILITY_DENIED} isChecking={false} onRecheck={noop} />);
    // Names the capability, why it's needed, and the exact System Settings path.
    expect(screen.getByRole("heading", { level: 3, name: /Accessibility/ })).toBeInTheDocument();
    // Exact match targets the path callout, not the step that repeats it.
    expect(
      screen.getByText("System Settings → Privacy & Security → Accessibility"),
    ).toBeInTheDocument();
    expect(screen.getByText(/move the pointer, click, and type/i)).toBeInTheDocument();
    // Granted Screen Recording carries no guidance.
    expect(screen.queryByText(/Screen Recording to see the windows/i)).not.toBeInTheDocument();
  });

  it("shows targeted Camera guidance when it is missing", () => {
    render(<PermissionsPanel report={CAMERA_DENIED} isChecking={false} onRecheck={noop} />);
    expect(screen.getByRole("heading", { level: 3, name: /Camera/ })).toBeInTheDocument();
    expect(screen.getByText("System Settings → Privacy & Security → Camera")).toBeInTheDocument();
    expect(screen.getByText(/Head pointing needs Camera/i)).toBeInTheDocument();
  });

  it("shows targeted Screen Recording guidance when it is missing", () => {
    render(
      <PermissionsPanel report={SCREEN_RECORDING_DENIED} isChecking={false} onRecheck={noop} />,
    );
    expect(screen.getByRole("heading", { level: 3, name: /Screen Recording/ })).toBeInTheDocument();
    expect(
      screen.getByText("System Settings → Privacy & Security → Screen Recording"),
    ).toBeInTheDocument();
  });

  it("lists the ordered grant steps for a missing permission", () => {
    render(<PermissionsPanel report={ACCESSIBILITY_DENIED} isChecking={false} onRecheck={noop} />);
    const steps = screen.getAllByRole("listitem").map((item) => item.textContent);
    expect(steps.some((step) => /Open System Settings/.test(step ?? ""))).toBe(true);
    expect(steps.some((step) => /Re-check/.test(step ?? ""))).toBe(true);
  });

  it("confirms readiness when both grants are present", () => {
    render(<PermissionsPanel report={ALL_GRANTED} isChecking={false} onRecheck={noop} />);
    expect(
      screen.getByText(new RegExp(`${APP_NAME} can\\s+track your head point`, "i")),
    ).toBeInTheDocument();
    // No setup steps when nothing is blocked.
    expect(screen.queryByRole("listitem")).not.toBeInTheDocument();
  });

  it("re-checks readiness when the button is pressed", () => {
    const onRecheck = vi.fn();
    render(
      <PermissionsPanel report={ACCESSIBILITY_DENIED} isChecking={false} onRecheck={onRecheck} />,
    );
    fireEvent.click(screen.getByRole("button", { name: "Re-check" }));
    expect(onRecheck).toHaveBeenCalledTimes(1);
  });

  it("disables the button and shows progress while a check is in flight", () => {
    render(<PermissionsPanel report={ACCESSIBILITY_DENIED} isChecking onRecheck={noop} />);
    const button = screen.getByRole("button", { name: /Checking/ });
    expect(button).toBeDisabled();
  });
});

// Microphone + speech accept/manage controls (#31).
const MEDIA_NOT_GRANTED = report([
  { id: "camera", kind: "permission", state: "not-determined" },
  { id: "microphone", kind: "permission", state: "not-determined" },
  { id: "speech-recognition", kind: "permission", state: "not-determined" },
]);

const MEDIA_GRANTED = report([
  { id: "camera", kind: "permission", state: "granted" },
  { id: "microphone", kind: "permission", state: "granted" },
  { id: "speech-recognition", kind: "permission", state: "granted" },
]);

describe("PermissionsPanel — head capture media", () => {
  it("shows the camera, microphone, and speech statuses", () => {
    render(<PermissionsPanel report={MEDIA_NOT_GRANTED} isChecking={false} onRecheck={noop} />);
    expect(
      screen.getByRole("heading", { level: 3, name: /Head Capture Media/ }),
    ).toBeInTheDocument();
    expect(screen.getByText(/Camera · /)).toBeInTheDocument();
    expect(screen.getByText(/Microphone · /)).toBeInTheDocument();
    expect(screen.getByText(/Speech Recognition · /)).toBeInTheDocument();
  });

  it("requests the OS prompt when Allow is pressed", () => {
    const onRequestMedia = vi.fn();
    render(
      <PermissionsPanel
        report={MEDIA_NOT_GRANTED}
        isChecking={false}
        onRecheck={noop}
        onRequestMedia={onRequestMedia}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /Allow camera, microphone & speech/ }));
    expect(onRequestMedia).toHaveBeenCalledTimes(1);
  });

  it("opens the right System Settings pane to manage a permission", () => {
    const onOpenSettings = vi.fn();
    render(
      <PermissionsPanel
        report={MEDIA_NOT_GRANTED}
        isChecking={false}
        onRecheck={noop}
        onOpenSettings={onOpenSettings}
      />,
    );
    // The first media "Open System Settings" button is camera's.
    fireEvent.click(screen.getAllByRole("button", { name: "Open System Settings" })[0]!);
    expect(onOpenSettings).toHaveBeenCalledWith("camera");
  });

  it("hides Allow and offers Manage once both are granted", () => {
    render(
      <PermissionsPanel
        report={MEDIA_GRANTED}
        isChecking={false}
        onRecheck={noop}
        onOpenSettings={noop}
      />,
    );
    expect(
      screen.queryByRole("button", { name: /Allow camera, microphone & speech/ }),
    ).not.toBeInTheDocument();
    expect(screen.getAllByRole("button", { name: "Manage" })).toHaveLength(3);
  });
});
