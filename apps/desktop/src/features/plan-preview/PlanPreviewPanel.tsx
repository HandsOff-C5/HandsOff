import { EmptyPanel } from "../../components/EmptyPanel";

// Placeholder. The visible plan-before-act preview lands with the intent lane.
export function PlanPreviewPanel() {
  return (
    <EmptyPanel
      title="Plan preview"
      message="No plan to preview yet. Proposed plans show here before you approve them."
    />
  );
}
