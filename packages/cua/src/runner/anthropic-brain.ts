import type { BrainStep } from "./computer-use-loop";

// STUB — red phase. The failing test demands the real brain seam.
export const COMPUTER_USE_MODEL = "";
export const COMPUTER_USE_BETA = "";

export function buildComputerUseTool(opts: {
  widthPx: number;
  heightPx: number;
  displayNumber?: number;
  enableZoom?: boolean;
}): Record<string, unknown> {
  return { display_width_px: opts.widthPx };
}

export function parseBrainStep(message: unknown): BrainStep {
  void message;
  return { text: "", actions: [], stopReason: "end_turn" };
}
