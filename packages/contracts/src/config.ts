import { z } from "zod";

// Non-secret local preferences for the desktop shell (#16). API keys and other
// credentials are intentionally out of scope; provider auth belongs in secure
// storage owned by the provider lane.
//
// `STT_PROVIDERS` is the source of truth for valid providers. The Rust
// `SttProvider` enum in `apps/desktop/src-tauri/src/commands/storage.rs` mirrors
// this list; keep the two in sync. The native side recovers any value it cannot
// deserialize back to the default, so a drift surfaces as a silent reset.
//
// The two transcription modes (AD2): "native" = macOS on-device recognition
// (default — no key, no network); "assemblyai" = hosted realtime streaming.
// User-facing labels deliberately avoid the provider names; see SettingsPanel.

export const STT_PROVIDERS = ["native", "assemblyai"] as const;
export const HEAD_POINTER_MOVEMENT_MODES = ["edge", "relative"] as const;

export const sttProviderSchema = z.enum(STT_PROVIDERS);
export type SttProvider = z.infer<typeof sttProviderSchema>;

export const headPointerMovementModeSchema = z.enum(HEAD_POINTER_MOVEMENT_MODES);
export type HeadPointerMovementMode = z.infer<typeof headPointerMovementModeSchema>;

export const headPointerConfigSchema = z.object({
  movementMode: headPointerMovementModeSchema,
  speed: z.number().min(1).max(10),
  distanceToEdge: z.number().min(0.02).max(0.4),
});
export type HeadPointerConfig = z.infer<typeof headPointerConfigSchema>;

export const localConfigSchema = z.object({
  sttProvider: sttProviderSchema,
  headPointer: headPointerConfigSchema,
});
export type LocalConfig = z.infer<typeof localConfigSchema>;

export const DEFAULT_LOCAL_CONFIG: LocalConfig = {
  sttProvider: "native",
  headPointer: {
    movementMode: "edge",
    speed: 5,
    distanceToEdge: 0.12,
  },
};

export function safeParseLocalConfig(input: unknown): z.SafeParseReturnType<unknown, LocalConfig> {
  return localConfigSchema.safeParse(input);
}
