import { safeParseObservabilityRecord, type ObservabilityRecord } from "@handsoff/contracts";

const DEFAULT_ASSEMBLYAI_TOKEN_ENDPOINT = "https://streaming.assemblyai.com/v3/token";
const DEFAULT_EXPIRES_SECONDS = 60;
const MIN_EXPIRES_SECONDS = 1;
const MAX_EXPIRES_SECONDS = 600;
const COMPONENT = "workers.assemblyai-token";
const ROUTE = "/v1/realtime-token";
const encoder = new TextEncoder();

interface ObservabilitySink {
  emit(record: ObservabilityRecord): void;
}

export interface Env {
  readonly ASSEMBLYAI_API_KEY: string;
  readonly HANDSOFF_APP_TOKEN: string;
  readonly ASSEMBLYAI_TOKEN_ENDPOINT?: string;
  readonly OBSERVABILITY_SINK?: ObservabilitySink;
}

interface AssemblyAiTokenResponse {
  readonly token: unknown;
  readonly expires_in_seconds: unknown;
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
  assemblyai_api_key_missing: "AssemblyAiApiKeyMissingError",
  assemblyai_token_endpoint_invalid: "AssemblyAiTokenEndpointInvalidError",
  assemblyai_token_request_failed: "AssemblyAiTokenRequestFailedError",
  handsoff_app_token_missing: "HandsoffAppTokenMissingError",
  invalid_app_credential: "InvalidAppCredentialError",
  invalid_assemblyai_token_response: "InvalidAssemblyAiTokenResponseError",
  invalid_expires_in_seconds: "InvalidExpiresInSecondsError",
  internal_server_error: "InternalServerError",
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
  if (!parsed.success) return;
  try {
    sink?.emit(parsed.data);
  } catch {
    // Observability must never change the Worker's user-facing response.
  }
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
  try {
    const response = await handler();
    const durationMs = Math.max(0, Math.round((performance.now() - started) * 100) / 100);
    await emitRequestRecords(env.OBSERVABILITY_SINK, context, response, durationMs);
    return response;
  } catch {
    const response = json({ error: "internal_server_error" }, 500);
    const durationMs = Math.max(0, Math.round((performance.now() - started) * 100) / 100);
    await emitRequestRecords(env.OBSERVABILITY_SINK, context, response, durationMs);
    return response;
  }
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

function parseExpires(requestUrl: URL): number | Response {
  const raw = requestUrl.searchParams.get("expires_in_seconds");
  if (raw === null) return DEFAULT_EXPIRES_SECONDS;
  if (!/^\d+$/.test(raw)) return json({ error: "invalid_expires_in_seconds" }, 400);
  const parsed = Number(raw);
  if (!Number.isInteger(parsed) || parsed < MIN_EXPIRES_SECONDS || parsed > MAX_EXPIRES_SECONDS) {
    return json({ error: "invalid_expires_in_seconds" }, 400);
  }
  return parsed;
}

function tokenEndpoint(env: Env, expiresInSeconds: number): string | Response {
  let url: URL;
  try {
    url = new URL(env.ASSEMBLYAI_TOKEN_ENDPOINT ?? DEFAULT_ASSEMBLYAI_TOKEN_ENDPOINT);
  } catch {
    return json({ error: "assemblyai_token_endpoint_invalid" }, 500);
  }
  if (url.protocol !== "https:") {
    return json({ error: "assemblyai_token_endpoint_invalid" }, 500);
  }
  url.searchParams.set("expires_in_seconds", String(expiresInSeconds));
  return url.toString();
}

function parseTokenResponse(
  body: AssemblyAiTokenResponse,
): { token: string; expiresInSeconds: number } | Response {
  if (
    typeof body.token !== "string" ||
    body.token.trim() === "" ||
    typeof body.expires_in_seconds !== "number" ||
    !Number.isInteger(body.expires_in_seconds) ||
    body.expires_in_seconds < MIN_EXPIRES_SECONDS ||
    body.expires_in_seconds > MAX_EXPIRES_SECONDS
  ) {
    return json({ error: "invalid_assemblyai_token_response" }, 502);
  }
  return {
    token: body.token,
    expiresInSeconds: body.expires_in_seconds,
  };
}

async function handleTokenRequest(request: Request, env: Env): Promise<Response> {
  if (request.method !== "GET") {
    return Response.json(
      { error: "method_not_allowed" },
      { status: 405, headers: { allow: "GET", "cache-control": "no-store" } },
    );
  }

  const appToken = readSecret(env.HANDSOFF_APP_TOKEN, "HANDSOFF_APP_TOKEN");
  if (appToken instanceof Response) return appToken;

  const incomingToken = bearerToken(request);
  if (incomingToken === null) return json({ error: "missing_app_credential" }, 401);
  if (!tokenEquals(incomingToken, appToken)) {
    return json({ error: "invalid_app_credential" }, 403);
  }

  const assemblyAiApiKey = readSecret(env.ASSEMBLYAI_API_KEY, "ASSEMBLYAI_API_KEY");
  if (assemblyAiApiKey instanceof Response) return assemblyAiApiKey;

  const expiresInSeconds = parseExpires(new URL(request.url));
  if (expiresInSeconds instanceof Response) return expiresInSeconds;

  let upstream: Response;
  try {
    const endpoint = tokenEndpoint(env, expiresInSeconds);
    if (endpoint instanceof Response) return endpoint;
    upstream = await fetch(endpoint, {
      headers: { Authorization: assemblyAiApiKey },
    });
  } catch {
    return json({ error: "assemblyai_token_request_failed" }, 502);
  }

  if (!upstream.ok) return json({ error: "assemblyai_token_request_failed" }, 502);

  let body: AssemblyAiTokenResponse;
  try {
    body = (await upstream.json()) as AssemblyAiTokenResponse;
  } catch {
    return json({ error: "invalid_assemblyai_token_response" }, 502);
  }

  const token = parseTokenResponse(body);
  if (token instanceof Response) return token;
  return json(token);
}

export const __test = { observeRequest };

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const route = url.pathname === ROUTE ? ROUTE : "not_found";
    return observeRequest(request, env, route, async () => {
      if (url.pathname !== ROUTE) return json({ error: "not_found" }, 404);
      return handleTokenRequest(request, env);
    });
  },
} satisfies ExportedHandler<Env>;
