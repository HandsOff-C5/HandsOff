import OpenAI from "openai";
import { zodResponseFormat } from "openai/helpers/zod";

// U3b: the loop emits the NEXT driver tool call, so the Worker structures the
// completion with the next-tool-call schema (was the 6-kind action-plan schema).
import { nextToolCallSchema } from "@handsoff/intent/src/llm/next-tool-call";

const DEFAULT_MODEL = "gpt-4o-mini";
const encoder = new TextEncoder();

export interface Env {
  readonly OPENAI_API_KEY: string;
  readonly HANDSOFF_APP_TOKEN: string;
}

interface IntentRequestBody {
  readonly model?: unknown;
  readonly messages?: unknown;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

function readSecret(value: string | undefined, name: string): string | Response {
  if (typeof value !== "string" || value.trim() === "") {
    return json({ error: `${name.toLowerCase()}_missing` }, 500);
  }
  return value.trim();
}

function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  if (!header?.startsWith("Bearer ")) return null;
  const token = header.slice("Bearer ".length).trim();
  return token === "" ? null : token;
}

function tokenEquals(left: string, right: string): boolean {
  const leftBytes = encoder.encode(left);
  const rightBytes = encoder.encode(right);
  let diff = leftBytes.length ^ rightBytes.length;
  const byteLength = Math.max(leftBytes.length, rightBytes.length);
  for (let index = 0; index < byteLength; index += 1) {
    diff |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }
  return diff === 0;
}

function parseIntentRequest(
  body: IntentRequestBody,
): { model: string; messages: unknown[] } | Response {
  const model =
    typeof body.model === "string" && body.model.trim() ? body.model.trim() : DEFAULT_MODEL;
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return json({ error: "invalid_intent_request" }, 400);
  }
  return { model, messages: body.messages };
}

async function handleIntentRequest(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return Response.json(
      { error: "method_not_allowed" },
      { status: 405, headers: { allow: "POST", "cache-control": "no-store" } },
    );
  }

  const appToken = readSecret(env.HANDSOFF_APP_TOKEN, "HANDSOFF_APP_TOKEN");
  if (appToken instanceof Response) return appToken;

  const incomingToken = bearerToken(request);
  if (incomingToken === null) return json({ error: "missing_app_credential" }, 401);
  if (!tokenEquals(incomingToken, appToken)) return json({ error: "invalid_app_credential" }, 403);

  const openAiApiKey = readSecret(env.OPENAI_API_KEY, "OPENAI_API_KEY");
  if (openAiApiKey instanceof Response) return openAiApiKey;

  let rawBody: IntentRequestBody;
  try {
    rawBody = (await request.json()) as IntentRequestBody;
  } catch {
    return json({ error: "invalid_intent_request" }, 400);
  }

  const parsed = parseIntentRequest(rawBody);
  if (parsed instanceof Response) return parsed;

  try {
    const client = new OpenAI({ apiKey: openAiApiKey });
    const completion = await client.chat.completions.parse({
      model: parsed.model,
      messages: parsed.messages as OpenAI.Chat.ChatCompletionMessageParam[],
      response_format: zodResponseFormat(nextToolCallSchema, "next_tool_call"),
    });
    return json({ choices: completion.choices });
  } catch {
    return json({ error: "openai_intent_request_failed" }, 502);
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== "/v1/resolve-intent") return json({ error: "not_found" }, 404);
    return handleIntentRequest(request, env);
  },
} satisfies ExportedHandler<Env>;
