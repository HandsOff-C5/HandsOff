import type { IntentInput, ResolvedIntent } from "@handsoff/contracts";

import { fuseIntent, type FuseIntentOptions } from "./fuse-intent";
import { resolveWithOpenAi, type OpenAiIntentResolverOptions } from "./llm/openai-resolver";

export type IntentResolverMode = "rule" | "llm";

export type ResolveIntentOptions = FuseIntentOptions &
  OpenAiIntentResolverOptions & {
    readonly resolver?: IntentResolverMode;
  };

export async function resolveIntent(
  input: IntentInput,
  options: ResolveIntentOptions = {},
): Promise<ResolvedIntent> {
  return options.resolver === "rule"
    ? fuseIntent(input, options)
    : resolveWithOpenAi(input, options);
}
