// Director email-capture Worker.
// Collects customer emails into Supabase and sends a Loops confirmation email.
// All provider credentials (Supabase service-role key, Loops key) live ONLY here
// as Worker secrets — the desktop app ships none, it presents HANDSOFF_APP_TOKEN.

const DEFAULT_CONFIRM_BASE = "https://forthedirector.com/confirmed";
const LOOPS_TRANSACTIONAL_ENDPOINT = "https://app.loops.so/api/v1/transactional";
const MAX_EMAIL_LENGTH = 254;
// Pragmatic single-line email check — good enough for capture, real validation is the confirm click.
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const encoder = new TextEncoder();

export interface Env {
  readonly SUPABASE_URL: string;
  readonly SUPABASE_SERVICE_ROLE_KEY: string;
  readonly LOOPS_API_KEY: string;
  readonly HANDSOFF_APP_TOKEN: string;
  readonly LOOPS_TRANSACTIONAL_ID: string;
  readonly CONFIRM_BASE_URL?: string;
}

interface SubscribeBody {
  readonly email?: unknown;
  readonly source?: unknown;
}

interface SubscriberRow {
  readonly confirmation_token: string;
  readonly confirmed: boolean;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status, headers: { "cache-control": "no-store" } });
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

// Constant-time comparison (mirrors the assemblyai-token Worker).
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

function requireAppToken(request: Request, env: Env): Response | null {
  const appToken = readSecret(env.HANDSOFF_APP_TOKEN, "HANDSOFF_APP_TOKEN");
  if (appToken instanceof Response) return appToken;
  const incoming = bearerToken(request);
  if (incoming === null) return json({ error: "missing_app_credential" }, 401);
  if (!tokenEquals(incoming, appToken)) return json({ error: "invalid_app_credential" }, 403);
  return null;
}

function normalizeEmail(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const email = value.trim().toLowerCase();
  if (email.length === 0 || email.length > MAX_EMAIL_LENGTH) return null;
  if (!EMAIL_RE.test(email)) return null;
  return email;
}

function supabaseHeaders(serviceKey: string): HeadersInit {
  return {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
    "content-type": "application/json",
  };
}

// Insert the subscriber. On conflict (already captured), fetch the existing row
// so we can still (re)send the confirmation for an unconfirmed address.
async function upsertSubscriber(
  env: Env,
  serviceKey: string,
  email: string,
  source: string | null,
): Promise<SubscriberRow | Response> {
  const base = env.SUPABASE_URL.replace(/\/+$/, "");
  let insert: Response;
  try {
    insert = await fetch(`${base}/rest/v1/subscribers`, {
      method: "POST",
      headers: { ...supabaseHeaders(serviceKey), Prefer: "return=representation" },
      body: JSON.stringify({ email, source }),
    });
  } catch {
    return json({ error: "supabase_unreachable" }, 502);
  }

  if (insert.status === 201) {
    const rows = (await insert.json()) as SubscriberRow[];
    const row = rows[0];
    if (!row) return json({ error: "supabase_insert_failed" }, 502);
    return row;
  }

  // 409 = duplicate email (unique index). Read the existing row.
  if (insert.status === 409) {
    let existing: Response;
    try {
      existing = await fetch(
        `${base}/rest/v1/subscribers?email=eq.${encodeURIComponent(email)}&select=confirmation_token,confirmed`,
        { headers: supabaseHeaders(serviceKey) },
      );
    } catch {
      return json({ error: "supabase_unreachable" }, 502);
    }
    const rows = (await existing.json()) as SubscriberRow[];
    const row = rows[0];
    if (!row) return json({ error: "supabase_lookup_failed" }, 502);
    return row;
  }

  return json({ error: "supabase_insert_failed" }, 502);
}

// Loops owns the subject/HTML/from in a dashboard template; the call only carries
// the recipient and the confirmation link as a `{{confirmationUrl}}` variable.
async function sendConfirmation(
  env: Env,
  loopsKey: string,
  email: string,
  token: string,
): Promise<Response | null> {
  const confirmBase = (env.CONFIRM_BASE_URL ?? DEFAULT_CONFIRM_BASE).replace(/\/+$/, "");
  const confirmUrl = `${confirmBase}?token=${encodeURIComponent(token)}`;

  let resp: Response;
  try {
    resp = await fetch(LOOPS_TRANSACTIONAL_ENDPOINT, {
      method: "POST",
      headers: { Authorization: `Bearer ${loopsKey}`, "content-type": "application/json" },
      body: JSON.stringify({
        transactionalId: env.LOOPS_TRANSACTIONAL_ID,
        email,
        dataVariables: { confirmationUrl: confirmUrl },
      }),
    });
  } catch {
    return json({ error: "loops_unreachable" }, 502);
  }
  // Loops can return 200 with { success: false } on a template/recipient problem.
  const body = (await resp.json().catch(() => null)) as { success?: boolean } | null;
  if (!resp.ok || body?.success === false) return json({ error: "loops_send_failed" }, 502);
  return null;
}

async function handleSubscribe(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const authError = requireAppToken(request, env);
  if (authError) return authError;

  const supabaseUrl = readSecret(env.SUPABASE_URL, "SUPABASE_URL");
  if (supabaseUrl instanceof Response) return supabaseUrl;
  const serviceKey = readSecret(env.SUPABASE_SERVICE_ROLE_KEY, "SUPABASE_SERVICE_ROLE_KEY");
  if (serviceKey instanceof Response) return serviceKey;
  const loopsKey = readSecret(env.LOOPS_API_KEY, "LOOPS_API_KEY");
  if (loopsKey instanceof Response) return loopsKey;

  let body: SubscribeBody;
  try {
    body = (await request.json()) as SubscribeBody;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const email = normalizeEmail(body.email);
  if (email === null) return json({ error: "invalid_email" }, 400);
  const source = typeof body.source === "string" ? body.source.slice(0, 64) : null;

  const row = await upsertSubscriber(env, serviceKey, email, source);
  if (row instanceof Response) return row;

  // Already confirmed → nothing to send, treat as success (idempotent).
  if (row.confirmed) return json({ status: "already_confirmed" });

  const sendError = await sendConfirmation(env, loopsKey, email, row.confirmation_token);
  if (sendError) return sendError;

  return json({ status: "confirmation_sent" }, 202);
}

async function handleConfirm(request: Request, env: Env): Promise<Response> {
  if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);

  const serviceKey = readSecret(env.SUPABASE_SERVICE_ROLE_KEY, "SUPABASE_SERVICE_ROLE_KEY");
  if (serviceKey instanceof Response) return serviceKey;
  const supabaseUrl = readSecret(env.SUPABASE_URL, "SUPABASE_URL");
  if (supabaseUrl instanceof Response) return supabaseUrl;

  const token = new URL(request.url).searchParams.get("token");
  if (!token || !/^[0-9a-fA-F-]{36}$/.test(token)) return json({ error: "invalid_token" }, 400);

  const base = supabaseUrl.replace(/\/+$/, "");
  let resp: Response;
  try {
    resp = await fetch(
      `${base}/rest/v1/subscribers?confirmation_token=eq.${token}&confirmed=eq.false`,
      {
        method: "PATCH",
        headers: { ...supabaseHeaders(serviceKey), Prefer: "return=representation" },
        body: JSON.stringify({ confirmed: true, confirmed_at: new Date().toISOString() }),
      },
    );
  } catch {
    return json({ error: "supabase_unreachable" }, 502);
  }

  if (!resp.ok) return json({ error: "confirm_failed" }, 502);
  const rows = (await resp.json()) as unknown[];
  // Zero rows = bad/expired token or already confirmed. Idempotent success either way.
  return json({ status: rows.length > 0 ? "confirmed" : "already_confirmed_or_unknown" });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/v1/subscribe") return handleSubscribe(request, env);
    if (url.pathname === "/v1/confirm") return handleConfirm(request, env);
    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
