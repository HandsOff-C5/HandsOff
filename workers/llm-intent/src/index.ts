import OpenAI from "openai";
import { zodResponseFormat } from "openai/helpers/zod";

import { safeParseObservabilityRecord, type ObservabilityRecord } from "@handsoff/contracts";

// U3b: the loop emits the NEXT driver tool call, so the Worker structures the
// completion with the next-tool-call schema (was the 6-kind action-plan schema).
import { nextToolCallSchema } from "@handsoff/intent/src/llm/next-tool-call";

const DEFAULT_OPENAI_MODEL = "gpt-4o-mini";
const DEFAULT_GEMINI_MODEL = "gemini-3.5-flash";
const GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/openai/";
const COMPONENT = "workers.llm-intent";
const ROUTE = "/v1/resolve-intent";
const encoder = new TextEncoder();

interface ObservabilitySink {
  emit(record: ObservabilityRecord): void;
}

export interface Env {
  readonly OPENAI_API_KEY?: string;
  readonly GEMINI_API_KEY?: string;
  readonly GOOGLE_API_KEY?: string;
  readonly OPENAI_MODEL?: string;
  readonly GEMINI_MODEL?: string;
  readonly HANDSOFF_APP_TOKEN: string;
  readonly OBSERVABILITY_SINK?: ObservabilitySink;
}

interface IntentRequestBody {
  readonly model?: unknown;
  readonly messages?: unknown;
}

interface ObservabilityContext {
  readonly requestId: string;
  readonly route: string;
  readonly method: string;
  readonly sessionId?: string;
  readonly correlationId: string;
  readonly traceId: string;
  readonly spanId: string;
}

const ERROR_CLASS_BY_CODE: Record<string, string> = {
  handsoff_app_token_missing: "HandsoffAppTokenMissingError",
  invalid_app_credential: "InvalidAppCredentialError",
  invalid_intent_request: "InvalidIntentRequestError",
  intent_provider_missing: "IntentProviderMissingError",
  intent_request_failed: "IntentRequestFailedError",
  method_not_allowed: "MethodNotAllowedError",
  missing_app_credential: "MissingAppCredentialError",
  not_found: "NotFoundError",
};

function json(body: unknown, status = 200): Response {
  return Response.json(body, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

function headerValue(request: Request, name: string): string | null {
  const value = request.headers.get(name)?.trim();
  return value ? value : null;
}

function generatedId(): string {
  return crypto.randomUUID().replaceAll("-", "");
}

function traceIdForRequest(request: Request, fallback: string): string {
  const traceparent = headerValue(request, "traceparent");
  const match = traceparent?.match(/^00-([a-f0-9]{32})-[a-f0-9]{16}-[a-f0-9]{2}$/i);
  return match?.[1] ?? fallback;
}

function methodLabel(method: string): string {
  return ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"].includes(method)
    ? method
    : "OTHER";
}

function observabilityContext(request: Request, route: string): ObservabilityContext {
  const requestId = headerValue(request, "x-request-id") ?? generatedId();
  const correlationId = headerValue(request, "x-correlation-id") ?? requestId;
  return {
    requestId,
    route,
    method: methodLabel(request.method),
    sessionId: headerValue(request, "x-handsoff-session-id") ?? undefined,
    correlationId,
    traceId: traceIdForRequest(request, correlationId),
    spanId: headerValue(request, "x-handsoff-span-id") ?? generatedId().slice(0, 16),
  };
}

function statusClass(status: number): string {
  return `${Math.trunc(status / 100)}xx`;
}

function fallbackErrorClass(status: number): string {
  return `Http${Math.trunc(status / 100)}xxError`;
}

async function errorClassForResponse(response: Response): Promise<string | null> {
  if (response.status < 400) return null;
  try {
    const body = (await response.clone().json()) as { error?: unknown };
    if (typeof body.error === "string") {
      return ERROR_CLASS_BY_CODE[body.error] ?? fallbackErrorClass(response.status);
    }
  } catch {
    // Body parsing is only for the Worker's own sanitized error envelope.
  }
  return fallbackErrorClass(response.status);
}

function emitRecord(sink: ObservabilitySink | undefined, record: ObservabilityRecord): void {
  const parsed = safeParseObservabilityRecord(record);
  if (parsed.success) sink?.emit(parsed.data);
}

async function emitRequestRecords(
  sink: ObservabilitySink | undefined,
  context: ObservabilityContext,
  response: Response,
  durationMs: number,
): Promise<void> {
  const timestamp = new Date().toISOString();
  const errorClass = await errorClassForResponse(response);
  const attributes = {
    request_id: context.requestId,
    route: context.route,
    method: context.method,
    http_status: response.status,
    status_class: statusClass(response.status),
    latency_ms: durationMs,
    ...(errorClass ? { error_class: errorClass } : {}),
  };
  const metricAttributes = {
    route: context.route,
    method: context.method,
    status_class: statusClass(response.status),
    ...(errorClass ? { error_class: errorClass } : {}),
  };
  const base = {
    timestamp,
    component: COMPONENT,
    sessionId: context.sessionId,
    correlationId: context.correlationId,
    traceId: context.traceId,
    spanId: context.spanId,
  };

  emitRecord(sink, {
    ...base,
    kind: "log",
    level: response.status >= 500 ? "error" : response.status >= 400 ? "warn" : "info",
    event: "request_finished",
    attributes,
  });
  emitRecord(sink, {
    ...base,
    kind: "span",
    event: "http.server.request",
    status: errorClass ? "error" : "ok",
    durationMs,
    attributes,
  });
  emitRecord(sink, {
    ...base,
    kind: "metric",
    event: "worker_request_latency",
    name: "worker.request.latency_ms",
    value: durationMs,
    unit: "ms",
    attributes: metricAttributes,
  });
  if (errorClass === null) return;
  emitRecord(sink, {
    ...base,
    kind: "error",
    event: "request_failed",
    errorClass,
    handled: true,
    attributes,
  });
  emitRecord(sink, {
    ...base,
    kind: "metric",
    event: "worker_request_error",
    name: "worker.request.error.count",
    value: 1,
    unit: "count",
    attributes: metricAttributes,
  });
}

async function observeRequest(
  request: Request,
  env: Env,
  route: string,
  handler: () => Promise<Response>,
): Promise<Response> {
  const started = performance.now();
  const context = observabilityContext(request, route);
  const response = await handler();
  const durationMs = Math.max(0, Math.round((performance.now() - started) * 100) / 100);
  await emitRequestRecords(env.OBSERVABILITY_SINK, context, response, durationMs);
  return response;
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
    const route = url.pathname === ROUTE ? ROUTE : "not_found";
    return observeRequest(request, env, route, async () => {
      if (url.pathname !== ROUTE) return json({ error: "not_found" }, 404);
      return handleIntentRequest(request, env);
    });
  },
} satisfies ExportedHandler<Env>;
