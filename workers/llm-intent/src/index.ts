import OpenAI from "openai";
import { zodResponseFormat } from "openai/helpers/zod";

// U3b: the loop emits the NEXT driver tool call, so the Worker structures the
// completion with the next-tool-call schema (was the 6-kind action-plan schema).
import { nextToolCallSchema } from "@handsoff/intent/src/llm/next-tool-call";

const DEFAULT_OPENAI_MODEL = "gpt-4o-mini";
const DEFAULT_GEMINI_MODEL = "gemini-3.5-flash";
const GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/openai/";
const encoder = new TextEncoder();

export interface Env {
  readonly OPENAI_API_KEY?: string;
  readonly GEMINI_API_KEY?: string;
  readonly GOOGLE_API_KEY?: string;
  readonly OPENAI_MODEL?: string;
  readonly GEMINI_MODEL?: string;
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

function optionalSecret(value: string | undefined): string | null {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
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
): { requestedModel: string | null; messages: unknown[] } | Response {
  const model = typeof body.model === "string" && body.model.trim() ? body.model.trim() : null;
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return json({ error: "invalid_intent_request" }, 400);
  }
  return { requestedModel: model, messages: body.messages };
}

interface IntentProvider {
  readonly name: "openai" | "gemini";
  readonly apiKey: string;
  readonly baseURL?: string;
  readonly model: string;
}

function configuredProviders(env: Env, requestedModel: string | null): IntentProvider[] {
  const providers: IntentProvider[] = [];
  const openAiApiKey = optionalSecret(env.OPENAI_API_KEY);
  if (openAiApiKey !== null) {
    providers.push({
      name: "openai",
      apiKey: openAiApiKey,
      model: optionalSecret(env.OPENAI_MODEL) ?? requestedModel ?? DEFAULT_OPENAI_MODEL,
    });
  }

  const geminiApiKey = optionalSecret(env.GEMINI_API_KEY) ?? optionalSecret(env.GOOGLE_API_KEY);
  if (geminiApiKey !== null) {
    providers.push({
      name: "gemini",
      apiKey: geminiApiKey,
      baseURL: GEMINI_BASE_URL,
      model:
        optionalSecret(env.GEMINI_MODEL) ??
        (requestedModel?.startsWith("gemini-") ? requestedModel : DEFAULT_GEMINI_MODEL),
    });
  }
  return providers;
}

function isRetryableProviderCredentialFailure(caught: unknown): boolean {
  const status =
    typeof caught === "object" && caught !== null && "status" in caught
      ? Number((caught as { status?: unknown }).status)
      : NaN;
  if ([401, 402, 403, 429].includes(status)) return true;
  const code =
    typeof caught === "object" && caught !== null && "code" in caught
      ? String((caught as { code?: unknown }).code)
      : "";
  return /invalid|auth|quota|billing|funds|payment/i.test(code);
}

async function resolveWithProvider(
  provider: IntentProvider,
  messages: unknown[],
): Promise<{ choices: unknown[] }> {
  const client = new OpenAI({
    apiKey: provider.apiKey,
    baseURL: provider.baseURL,
    maxRetries: 0,
  });
  return client.chat.completions.parse({
    model: provider.model,
    messages: messages as OpenAI.Chat.ChatCompletionMessageParam[],
    response_format: zodResponseFormat(nextToolCallSchema, "next_tool_call"),
  });
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

  let rawBody: IntentRequestBody;
  try {
    rawBody = (await request.json()) as IntentRequestBody;
  } catch {
    return json({ error: "invalid_intent_request" }, 400);
  }

  const parsed = parseIntentRequest(rawBody);
  if (parsed instanceof Response) return parsed;

  const providers = configuredProviders(env, parsed.requestedModel);
  if (providers.length === 0) return json({ error: "intent_provider_missing" }, 500);

  for (const [index, provider] of providers.entries()) {
    try {
      const completion = await resolveWithProvider(provider, parsed.messages);
      return json({ choices: completion.choices });
    } catch (caught) {
      const hasFallback = index < providers.length - 1;
      if (!hasFallback || !isRetryableProviderCredentialFailure(caught)) {
        return json({ error: "intent_request_failed" }, 502);
      }
    }
  }

  return json({ error: "intent_request_failed" }, 502);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== "/v1/resolve-intent") return json({ error: "not_found" }, 404);
    return handleIntentRequest(request, env);
  },
} satisfies ExportedHandler<Env>;
