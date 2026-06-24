import { z } from "zod";

import { actionTargetSchema } from "./action-plan";
import { permissionStateSchema } from "./readiness";
import { surfaceSnapshotSchema } from "./surface";

export const cuaPermissionReportSchema = z.object({
  accessibility: permissionStateSchema,
  screenRecording: permissionStateSchema,
  driver: z.enum(["running", "unavailable", "unknown"]),
});
export type CuaPermissionReport = z.infer<typeof cuaPermissionReportSchema>;

export const cuaAppSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  pid: z.number().int().nonnegative().optional(),
  bundleId: z.string().min(1).optional(),
  running: z.boolean().optional(),
  active: z.boolean().optional(),
});
export type CuaApp = z.infer<typeof cuaAppSchema>;

export const cuaWindowSchema = surfaceSnapshotSchema.extend({
  focused: z.boolean().optional(),
});
export type CuaWindow = z.infer<typeof cuaWindowSchema>;

export const cuaElementSchema = z.object({
  id: z.string().min(1),
  index: z.number().int().nonnegative().optional(),
  role: z.string().optional(),
  label: z.string().optional(),
  value: z.string().optional(),
});
export type CuaElement = z.infer<typeof cuaElementSchema>;

export const cuaWindowStateSchema = z.object({
  surface: surfaceSnapshotSchema,
  capturedAt: z.string().datetime(),
  elementCount: z.number().int().nonnegative().default(0),
  elements: z.array(cuaElementSchema).default([]),
});
export type CuaWindowState = z.infer<typeof cuaWindowStateSchema>;

export const cuaScreenshotSchema = z.object({
  surface: surfaceSnapshotSchema,
  capturedAt: z.string().datetime(),
  mimeType: z.string().min(1),
  width: z.number().int().positive(),
  height: z.number().int().positive(),
  pngBase64: z.string().min(1).optional(),
});
export type CuaScreenshot = z.infer<typeof cuaScreenshotSchema>;

export type CuaResult<T> =
  | { status: "succeeded"; value: T }
  | { status: "failed"; error: string }
  | { status: "blocked"; reason: string };

// One tool as the driver self-describes it (`cua-driver list-tools` +
// `describe`). `inputSchema` is the driver's JSON Schema verbatim — we do not
// re-model per-tool shapes HandsOff-side; this is the agent's function set.
export const driverToolDefinitionSchema = z.object({
  name: z.string().min(1),
  description: z.string(),
  inputSchema: z.unknown().nullable(),
});
export type DriverToolDefinition = z.infer<typeof driverToolDefinitionSchema>;

export function safeParseDriverToolDefinitions(
  input: unknown,
): z.SafeParseReturnType<unknown, DriverToolDefinition[]> {
  return driverToolDefinitionSchema.array().safeParse(input);
}

export const cuaActionRequestSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("launch_app"),
    appName: z.string().min(1),
    bundleId: z.string().min(1).optional(),
  }),
  z.object({
    kind: z.literal("get_window_state"),
    target: actionTargetSchema,
  }),
  z.object({
    kind: z.literal("click"),
    target: actionTargetSchema,
  }),
  z.object({
    kind: z.literal("type_text"),
    target: actionTargetSchema,
    text: z.string().min(1),
  }),
  z.object({
    kind: z.literal("set_value"),
    target: actionTargetSchema,
    value: z.string(),
  }),
  z.object({
    kind: z.literal("screenshot"),
    target: actionTargetSchema,
  }),
]);
export type CuaActionRequest = z.infer<typeof cuaActionRequestSchema>;

export const cuaActionResultSchema = z.discriminatedUnion("status", [
  z.object({
    status: z.literal("succeeded"),
    summary: z.string().min(1),
    state: cuaWindowStateSchema.optional(),
  }),
  z.object({
    status: z.literal("failed"),
    error: z.string().min(1),
    state: cuaWindowStateSchema.optional(),
  }),
  z.object({
    status: z.literal("blocked"),
    reason: z.string().min(1),
    state: cuaWindowStateSchema.optional(),
  }),
]);
export type CuaActionResult = z.infer<typeof cuaActionResultSchema>;

export function safeParseCuaActionResult(
  input: unknown,
): z.SafeParseReturnType<unknown, CuaActionResult> {
  return cuaActionResultSchema.safeParse(input);
}

export function safeParseCuaWindowState(
  input: unknown,
): z.SafeParseReturnType<unknown, CuaWindowState> {
  return cuaWindowStateSchema.safeParse(input);
}
