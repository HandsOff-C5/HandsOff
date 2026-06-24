import type { ActionOutcome, ComputerUseBrain } from "./computer-use-loop";
import { CUA_AGENT_MODEL, parseCuaAgentStep } from "./ax-brain";

// A single Anthropic message in the running computer-use conversation. Kept
// structural so this module doesn't depend on the SDK types; the host adapter
// passes these straight to client.beta.messages.create({ messages }).
export type AnthropicContentBlock = Record<string, unknown>;
export type AnthropicMessage = { role: "user" | "assistant"; content: AnthropicContentBlock[] };

export type ComputerUseRequest = {
  model: string;
  betas: readonly string[];
  tools: readonly Record<string, unknown>[];
  messages: readonly AnthropicMessage[];
  max_tokens: number;
};

// The one host-coupled call, isolated behind a port: the live brain wires this
// to client.beta.messages.create (Anthropic SDK in a host process — Rust/worker,
// never the webview, since the key must not reach it). Returns the raw message,
// which parseBrainStep validates.
export type ComputerUseClient = {
  createMessage(request: ComputerUseRequest): Promise<unknown>;
};

const DEFAULT_MAX_TOKENS = 1024;

type RawMessageLike = { content?: readonly AnthropicContentBlock[] };

// Build the tool_result content for one executed action's outcome. The model
// sees the fresh screenshot (or text), or an is_error result it can recover from.
function toolResultBlock(toolUseId: string, outcome: ActionOutcome): AnthropicContentBlock {
  if (outcome.status === "error") {
    return {
      type: "tool_result",
      tool_use_id: toolUseId,
      is_error: true,
      content: [{ type: "text", text: outcome.error }],
    };
  }
  if (outcome.screenshot !== undefined) {
    return {
      type: "tool_result",
      tool_use_id: toolUseId,
      content: [
        {
          type: "image",
          source: { type: "base64", media_type: "image/png", data: outcome.screenshot },
        },
      ],
    };
  }
  return {
    type: "tool_result",
    tool_use_id: toolUseId,
    content: [{ type: "text", text: outcome.text ?? "(no output)" }],
  };
}

// Build the live computer-use brain. It is STATEFUL across the loop run (one
// brain per run): it keeps the real Anthropic message history, because the
// API requires the assistant turns to be echoed back verbatim and each
// tool_result paired to a real tool_use id — neither of which the loop's
// distilled LoopEntry transcript preserves. Each next():
//   1. first turn  -> seed [user: goal];
//      later turns -> append one user message of tool_result blocks for the
//      actions executed since the previous turn (paired, in order, to the
//      tool_use ids from the previous assistant turn);
//   2. call the injected client;
//   3. store the assistant turn verbatim (+ its tool_use ids) for next time;
//   4. return parseBrainStep(raw).
export function createAnthropicBrain(opts: {
  client: ComputerUseClient;
  tool: Record<string, unknown>;
  model?: string;
  betas?: readonly string[];
  maxTokens?: number;
}): ComputerUseBrain {
  const messages: AnthropicMessage[] = [];
  let lastToolUseIds: string[] = [];
  let consumed = 0;

  return {
    async next({ goal, transcript }) {
      if (messages.length === 0) {
        messages.push({ role: "user", content: [{ type: "text", text: goal }] });
      } else {
        // Pair the actions executed since the last turn (in order) to the
        // tool_use ids the model emitted in the previous assistant turn.
        const fresh = transcript.slice(consumed);
        const results: AnthropicContentBlock[] = [];
        let idIndex = 0;
        for (const entry of fresh) {
          if (entry.kind !== "action") continue;
          const toolUseId = lastToolUseIds[idIndex] ?? "";
          idIndex += 1;
          results.push(toolResultBlock(toolUseId, entry.outcome));
        }
        if (results.length > 0) messages.push({ role: "user", content: results });
      }
      consumed = transcript.length;

      const raw = await opts.client.createMessage({
        model: opts.model ?? CUA_AGENT_MODEL,
        betas: opts.betas ?? [],
        tools: [opts.tool],
        messages: [...messages],
        max_tokens: opts.maxTokens ?? DEFAULT_MAX_TOKENS,
      });

      const content = (raw as RawMessageLike).content ?? [];
      messages.push({ role: "assistant", content: [...content] });
      lastToolUseIds = content
        .filter((block) => block.type === "tool_use")
        .map((block) => (typeof block.id === "string" ? block.id : ""));

      return parseCuaAgentStep(raw);
    },
  };
}
