import { useEffect } from "react";

// Full-screen pointing overlay (#25 cursor seam) — the layer that draws where you
// point on the REAL desktop, in its own transparent, click-through, always-on-top
// window. Step 1: prove the window shows over the desktop and that clicks pass
// through. The live dot + target label are wired next (events from the main window).
export function PointingOverlay() {
  // The shared bundle's body is opaque dark (dashboard theme); the overlay window
  // must be see-through, so clear the background while this layer is mounted.
  useEffect(() => {
    const { body, documentElement } = document;
    const prev = { body: body.style.background, html: documentElement.style.background };
    body.style.background = "transparent";
    documentElement.style.background = "transparent";
    return () => {
      body.style.background = prev.body;
      documentElement.style.background = prev.html;
    };
  }, []);

  return (
    <div className="pointing-overlay" aria-hidden="true">
      <div className="pointing-overlay__marker" />
      <p className="pointing-overlay__hint">HandsOff overlay active — clicks pass through</p>
    </div>
  );
}
