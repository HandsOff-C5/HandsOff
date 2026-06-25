import type { IntentInput, ResolvedIntent } from "@handsoff/contracts";
import { resolveNextToolCall, type ResolveNextToolCallOptions } from "@handsoff/intent";

export type IntentResolveInvoke = <T>(
  command: string,
  args?: Record<string, unknown>,
) => Promise<T>;

// The autonomous loop's resolver signature: emit the next driver tool call (as a
// ResolvedIntent carrying a tool_call step) toward the goal given the live state.
// `options.tools` is the driver catalog the controller loads from U1.
export type NextToolCallResolver = (
  input: IntentInput,
  options: ResolveNextToolCallOptions,
) => Promise<ResolvedIntent>;

// Adapt a Tauri `invoke` into the full-surface next-tool-call resolver: the
// model call is proxied to the `intent_resolve` backend command, keeping the
// loop coordinator free of IPC wiring.
export function createIntentWorkerResolver(invoke: IntentResolveInvoke): NextToolCallResolver {
  return (input, options) => {
    const client: NonNullable<ResolveNextToolCallOptions["client"]> = {
      chat: {
        completions: {
          async parse(request) {
            const { model, messages } = request as { model?: unknown; messages?: unknown };
            return invoke("intent_resolve", { request: { model, messages } });
          },
        },
      },
    };
    return resolveNextToolCall(input, { ...options, client });
  };
}
