import { EmptyPanel } from "../../components/EmptyPanel";

// Placeholder. Live surfaces (apps/windows) and manual selection land with the
// surfaces lane.
export function SurfacesPanel() {
  return (
    <EmptyPanel
      title="Surfaces"
      message="No live surfaces yet. Surface selection lands in a later milestone."
    />
  );
}
