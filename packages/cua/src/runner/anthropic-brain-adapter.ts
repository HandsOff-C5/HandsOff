import type { ComputerUseBrain } from "./computer-use-loop";

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

export function createAnthropicBrain(_opts: {
  client: ComputerUseClient;
  tool: Record<string, unknown>;
  model?: string;
  beta?: string;
  maxTokens?: number;
}): ComputerUseBrain {
  void _opts.client;
  throw new Error("not implemented");
}
