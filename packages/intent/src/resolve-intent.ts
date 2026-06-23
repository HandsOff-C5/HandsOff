import type { IntentInput, ResolvedIntent } from "@handsoff/contracts";

import { fuseIntent, type FuseIntentOptions } from "./fuse-intent";
import { resolveWithOpenAi, type OpenAiIntentResolverOptions } from "./llm/openai-resolver";

export type IntentResolverMode = "auto" | "rule" | "llm";

export type ResolveIntentOptions = FuseIntentOptions &
  OpenAiIntentResolverOptions & {
    readonly resolver?: IntentResolverMode;
  };

export async function resolveIntent(
  input: IntentInput,
  options: ResolveIntentOptions = {},
): Promise<ResolvedIntent> {
  if (options.resolver === "rule") {
    return fuseIntent(input, options);
  }

  const llm = await resolveWithOpenAi(input, options);
  if (options.resolver === "llm" || !isResolverFailure(llm)) {
    return llm;
  }

  const fallback = fuseIntent(input, options);
  return fallback.status === "blocked" && fallback.reason === "Unsupported voice command"
    ? llm
    : fallback;
}

function isResolverFailure(intent: ResolvedIntent): boolean {
  return (
    intent.status === "blocked" &&
    "reason" in intent &&
    intent.reason.startsWith("Intent resolver failed:")
  );
}
