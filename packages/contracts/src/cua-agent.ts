import { z } from "zod";

// The AX-native action vocabulary the CUA brain emits — one variant per
// `cua_*` driver command, discriminated on `kind`. This REPLACES the pixel
// `computer_20251124` ComputerAction model: the agent grounds on the window's
// AX `elements[]` and acts by `elementIndex` (the click handle from the latest
// snapshot), with `click_point` as a window-local pixel fallback for AX-blind
// surfaces (canvas / WebGL / video). pid + window_id are loop context the env
// supplies, not model-chosen, so the brain can only act within the active window.
const elementIndexSchema = z.number().int().nonnegative();

export const cuaAgentActionSchema = z.discriminatedUnion("kind", [
  // Re-read the active window (AX elements + screenshot). The brain's "look".
  z.object({ kind: z.literal("snapshot") }),
  // Primary action: AX press on an element by its snapshot index.
  z.object({ kind: z.literal("click"), elementIndex: elementIndexSchema }),
  // Pixel fallback: window-local screenshot pixels (top-left origin).
  z.object({
    kind: z.literal("click_point"),
    x: z.number(),
    y: z.number(),
    button: z.enum(["left", "right", "middle"]).optional(),
  }),
  z.object({ kind: z.literal("type_text"), elementIndex: elementIndexSchema, text: z.string() }),
  z.object({ kind: z.literal("set_value"), elementIndex: elementIndexSchema, value: z.string() }),
  z.object({
    kind: z.literal("press_key"),
    key: z.string().min(1),
    modifiers: z.array(z.string().min(1)).optional(),
    elementIndex: elementIndexSchema.optional(),
  }),
  // A chord (modifiers + one key), e.g. ["cmd","c"]; the driver requires ≥2.
  z.object({ kind: z.literal("hotkey"), keys: z.array(z.string().min(1)).min(2) }),
  z.object({
    kind: z.literal("scroll"),
    direction: z.enum(["up", "down", "left", "right"]),
    by: z.enum(["line", "page"]).optional(),
    amount: z.number().int().positive().optional(),
    elementIndex: elementIndexSchema.optional(),
  }),
  z.object({
    kind: z.literal("launch_app"),
    appName: z.string().min(1),
    bundleId: z.string().min(1).optional(),
  }),
]);
export type CuaAgentAction = z.infer<typeof cuaAgentActionSchema>;
export type CuaAgentActionKind = CuaAgentAction["kind"];

export function safeParseCuaAgentAction(
  input: unknown,
): z.SafeParseReturnType<unknown, CuaAgentAction> {
  return cuaAgentActionSchema.safeParse(input);
}
