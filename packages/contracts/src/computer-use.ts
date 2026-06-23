import { z } from "zod";

// The pixel-level action vocabulary of the Claude computer-use tool
// (`computer_20251124`, beta `computer-use-2025-11-24`). The CUA brain loop
// receives these as `tool_use.input` from the model and the driver executes
// them; the supervision audit trail records each one and the approval UI
// renders them. Field names mirror the API wire format EXACTLY (`coordinate`,
// `start_coordinate`, `scroll_direction`, `scroll_amount`, `duration`,
// `region`, and the overloaded `text` modifier) so a value round-trips between
// the Rust loop and this contract without translation.
//
// This is deliberately distinct from `CuaActionRequest` (cua.ts), which is the
// high-level element-target vocabulary of the deterministic planned path.

// A display coordinate, [x, y] in logical points, top-left origin, Y-down —
// the same coordinate space as MediaPipe (no flip). Range-checking against the
// display bounds is the environment's job, not the schema's.
export const computerCoordinateSchema = z.tuple([z.number().int(), z.number().int()]);
export type ComputerCoordinate = z.infer<typeof computerCoordinateSchema>;

export const scrollDirectionSchema = z.enum(["up", "down", "left", "right"]);
export type ScrollDirection = z.infer<typeof scrollDirectionSchema>;

// The complete `computer_20251124` action set. Guarded by a test so the union
// can't silently drift from what the model can emit.
export const COMPUTER_ACTION_KINDS = [
  "screenshot",
  "left_click",
  "right_click",
  "middle_click",
  "double_click",
  "triple_click",
  "mouse_move",
  "left_click_drag",
  "left_mouse_down",
  "left_mouse_up",
  "scroll",
  "type",
  "key",
  "hold_key",
  "wait",
  "cursor_position",
  "zoom",
] as const;
export type ComputerActionKind = (typeof COMPUTER_ACTION_KINDS)[number];

// Click-family actions all target a coordinate and accept an optional modifier
// key held during the click via the `text` field (e.g. "shift", "ctrl",
// "alt", "super").
// Generic over the literal so each click member keeps its narrow `action` type
// (a non-generic `kind: ComputerActionKind` would widen z.literal to the whole
// union and collapse the discriminated union, breaking narrowing downstream).
const clickActionSchema = <K extends ComputerActionKind>(kind: K) =>
  z.object({
    action: z.literal(kind),
    coordinate: computerCoordinateSchema,
    text: z.string().min(1).optional(),
  });

export const computerActionSchema = z.discriminatedUnion("action", [
  z.object({ action: z.literal("screenshot") }),
  z.object({ action: z.literal("cursor_position") }),
  z.object({ action: z.literal("mouse_move"), coordinate: computerCoordinateSchema }),
  clickActionSchema("left_click"),
  clickActionSchema("right_click"),
  clickActionSchema("middle_click"),
  clickActionSchema("double_click"),
  clickActionSchema("triple_click"),
  // Press / release at an optional coordinate for fine-grained drag control.
  z.object({
    action: z.literal("left_mouse_down"),
    coordinate: computerCoordinateSchema.optional(),
  }),
  z.object({
    action: z.literal("left_mouse_up"),
    coordinate: computerCoordinateSchema.optional(),
  }),
  z.object({
    action: z.literal("left_click_drag"),
    start_coordinate: computerCoordinateSchema,
    coordinate: computerCoordinateSchema,
  }),
  z.object({
    action: z.literal("scroll"),
    coordinate: computerCoordinateSchema,
    scroll_direction: scrollDirectionSchema,
    scroll_amount: z.number().int().nonnegative(),
    text: z.string().min(1).optional(),
  }),
  z.object({ action: z.literal("type"), text: z.string().min(1) }),
  z.object({ action: z.literal("key"), text: z.string().min(1) }),
  // Hold a key for `duration` seconds.
  z.object({
    action: z.literal("hold_key"),
    text: z.string().min(1),
    duration: z.number().positive(),
  }),
  // Pause for `duration` seconds between actions.
  z.object({ action: z.literal("wait"), duration: z.number().positive() }),
  // View a screen region [x1, y1, x2, y2] at full resolution (requires
  // `enable_zoom: true` in the tool definition).
  z.object({
    action: z.literal("zoom"),
    region: z.tuple([z.number().int(), z.number().int(), z.number().int(), z.number().int()]),
  }),
]);
export type ComputerAction = z.infer<typeof computerActionSchema>;

export function safeParseComputerAction(
  input: unknown,
): z.SafeParseReturnType<unknown, ComputerAction> {
  return computerActionSchema.safeParse(input);
}
