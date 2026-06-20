import { z } from "zod";

// Non-secret local preferences for the desktop shell (#16). API keys and other
// credentials are intentionally out of scope; provider auth belongs in secure
// storage owned by the provider lane.

export const STT_PROVIDERS = ["assemblyai", "mock"] as const;

export const sttProviderSchema = z.enum(STT_PROVIDERS);
export type SttProvider = z.infer<typeof sttProviderSchema>;

export const localConfigSchema = z.object({
  sttProvider: sttProviderSchema,
  demoMode: z.boolean(),
});
export type LocalConfig = z.infer<typeof localConfigSchema>;

export const DEFAULT_LOCAL_CONFIG: LocalConfig = {
  sttProvider: "assemblyai",
  demoMode: false,
};

export function safeParseLocalConfig(input: unknown): z.SafeParseReturnType<unknown, LocalConfig> {
  return localConfigSchema.safeParse(input);
}
