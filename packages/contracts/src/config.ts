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

export const sttProviderSchema = z.enum(STT_PROVIDERS);
export type SttProvider = z.infer<typeof sttProviderSchema>;

export const localConfigSchema = z.object({
  sttProvider: sttProviderSchema,
});
export type LocalConfig = z.infer<typeof localConfigSchema>;

export const DEFAULT_LOCAL_CONFIG: LocalConfig = {
  sttProvider: "native",
};

export function safeParseLocalConfig(input: unknown): z.SafeParseReturnType<unknown, LocalConfig> {
  return localConfigSchema.safeParse(input);
}
