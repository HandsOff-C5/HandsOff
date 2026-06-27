const DEFAULT_ASSEMBLYAI_TOKEN_ENDPOINT = "https://streaming.assemblyai.com/v3/token";
const DEFAULT_EXPIRES_SECONDS = 60;
const MIN_EXPIRES_SECONDS = 1;
const MAX_EXPIRES_SECONDS = 600;
const encoder = new TextEncoder();

export interface Env {
  readonly ASSEMBLYAI_API_KEY: string;
  readonly HANDSOFF_APP_TOKEN: string;
  readonly ASSEMBLYAI_TOKEN_ENDPOINT?: string;
}

interface AssemblyAiTokenResponse {
  readonly token: unknown;
  readonly expires_in_seconds: unknown;
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

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname !== "/v1/realtime-token") return json({ error: "not_found" }, 404);
    return handleTokenRequest(request, env);
  },
} satisfies ExportedHandler<Env>;
