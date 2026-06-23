// Registers @testing-library/jest-dom matchers (toBeInTheDocument, etc.) with
// Vitest's expect. Loaded via `test.setupFiles` in vite.config.ts.
import "@testing-library/jest-dom/vitest";

// jsdom doesn't implement HTMLMediaElement.play/pause (it throws + logs to the
// virtual console). Components that attach a webcam stream call play(); stub it
// so those tests don't spew "Not implemented" noise. No-ops, returns a promise.
if (typeof HTMLMediaElement !== "undefined") {
  HTMLMediaElement.prototype.play = () => Promise.resolve();
  HTMLMediaElement.prototype.pause = () => {};
}
