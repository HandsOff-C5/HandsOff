import { EmptyPanel } from "../../components/EmptyPanel";

// Placeholder. Capability readiness (camera, mic, CUA, Accessibility, Screen
// Recording → green/yellow/red) lands with the readiness lane.
export function ReadinessPanel() {
  return (
    <EmptyPanel
      title="Readiness"
      message="Permissions and capability readiness will appear here. Nothing checked yet."
    />
  );
}
