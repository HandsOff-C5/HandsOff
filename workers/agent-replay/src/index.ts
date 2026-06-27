const REPLAY_EVENTS_PATH = "/v1/agent-replay/events";
const TEST_SINK_PATH_PREFIX = "/v1/agent-replay/test-sink/";
const DEFAULT_LANGFUSE_BASE_URL = "https://cloud.langfuse.com";
const DEFAULT_RETENTION_DAYS = 30;
const encoder = new TextEncoder();

const replayEventTypes = [
  "session_started",
  "transcript_final",
  "prompt_built",
  "model_response",
  "intent_resolved",
  "approval_decided",
  "tool_call_started",
  "tool_call_finished",
  "loop_finished",
  "loop_failed",
] as const;

export type ReplayEventType = (typeof replayEventTypes)[number];

export interface AgentReplayEvent {
  readonly sessionId: string;
  readonly seq: number;
  readonly eventId: string;
  readonly type: ReplayEventType;
  readonly timestamp: string;
  readonly payload: unknown;
}

export interface ReplayTestSink {
  append(events: readonly AgentReplayEvent[]): Promise<void>;
  records(sessionId: string): Promise<readonly AgentReplayEvent[]>;
}

export interface Env {
  readonly HANDSOFF_APP_TOKEN: string;
  readonly LANGFUSE_PUBLIC_KEY?: string;
  readonly LANGFUSE_SECRET_KEY?: string;
  readonly LANGFUSE_BASE_URL?: string;
  readonly LANGFUSE_ENVIRONMENT?: string;
  readonly AGENT_REPLAY_DEDUP: KVNamespace;
  readonly AGENT_REPLAY_TEST_SINK?: ReplayTestSink;
}

interface ReplayRequestBody {
  readonly events?: unknown;
}

interface LangfuseBatchItem {
  readonly id: string;
  readonly timestamp: string;
  readonly type: "trace-create" | "event-create";
  readonly body: Record<string, unknown>;
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

function authenticate(request: Request, env: Env): Response | null {
  const appToken = readSecret(env.HANDSOFF_APP_TOKEN, "HANDSOFF_APP_TOKEN");
  if (appToken instanceof Response) return appToken;

  const incomingToken = bearerToken(request);
  if (incomingToken === null) return json({ error: "missing_app_credential" }, 401);
  if (!tokenEquals(incomingToken, appToken)) return json({ error: "invalid_app_credential" }, 403);
  return null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizedKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function forbiddenPayloadKey(key: string): boolean {
  const normalized = normalizedKey(key);
  if (normalized === "authorization" || normalized === "token") return true;
  return [
    "credential",
    "providerkey",
    "apikey",
    "appauthtoken",
    "bearertoken",
    "bearer",
    "cookie",
    "password",
    "secret",
    "screenshot",
    "pixel",
    "rawaudio",
    "rawvideo",
    "audioframe",
    "videoframe",
  ].some((fragment) => normalized.includes(fragment));
}

function forbiddenPayloadPath(value: unknown, path = "payload"): string | null {
  if (typeof value === "string") {
    return /\bbearer\s+[a-z0-9._~+/=-]+/i.test(value) ? path : null;
  }
  if (Array.isArray(value)) {
    for (const [index, item] of value.entries()) {
      const violation = forbiddenPayloadPath(item, `${path}[${index}]`);
      if (violation !== null) return violation;
    }
    return null;
  }
  if (!isRecord(value)) return null;

  for (const [key, item] of Object.entries(value)) {
    const nestedPath = `${path}.${key}`;
    if (forbiddenPayloadKey(key)) return nestedPath;
    const violation = forbiddenPayloadPath(item, nestedPath);
    if (violation !== null) return violation;
  }
  return null;
}

function parseEvent(raw: unknown, index: number): AgentReplayEvent | Response {
  if (!isRecord(raw)) {
    return json({ error: "invalid_agent_replay_event", index }, 400);
  }

  const sessionId = typeof raw.sessionId === "string" ? raw.sessionId.trim() : "";
  const eventId = typeof raw.eventId === "string" ? raw.eventId.trim() : "";
  const type = typeof raw.type === "string" ? raw.type.trim() : "";
  const timestamp = typeof raw.timestamp === "string" ? raw.timestamp.trim() : "";
  const seq = raw.seq;

  if (
    sessionId === "" ||
    eventId === "" ||
    !replayEventTypes.includes(type as ReplayEventType) ||
    !Number.isInteger(seq) ||
    Number(seq) < 0 ||
    timestamp === "" ||
    Number.isNaN(Date.parse(timestamp)) ||
    !("payload" in raw)
  ) {
    return json({ error: "invalid_agent_replay_event", index }, 400);
  }

  const violation = forbiddenPayloadPath(raw.payload);
  if (violation !== null) {
    return json({ error: "forbidden_agent_replay_payload", index, path: violation }, 400);
  }

  return {
    sessionId,
    seq: Number(seq),
    eventId,
    type: type as ReplayEventType,
    timestamp,
    payload: raw.payload,
  };
}

function parseReplayRequest(raw: ReplayRequestBody): AgentReplayEvent[] | Response {
  if (!isRecord(raw) || !Array.isArray(raw.events) || raw.events.length === 0) {
    return json({ error: "invalid_agent_replay_request" }, 400);
  }

  const events: AgentReplayEvent[] = [];
  for (const [index, item] of raw.events.entries()) {
    const parsed = parseEvent(item, index);
    if (parsed instanceof Response) return parsed;
    events.push(parsed);
  }
  return events;
}

function readDedupStore(env: Env): KVNamespace | Response {
  if (typeof env.AGENT_REPLAY_DEDUP?.get !== "function") {
    return json({ error: "agent_replay_dedup_missing" }, 500);
  }
  return env.AGENT_REPLAY_DEDUP;
}

function eventKey(eventId: string): string {
  return `event:${eventId}`;
}

function lastSeqKey(sessionId: string): string {
  return `session:${sessionId}:last_seq`;
}

interface PendingEvents {
  readonly eventsToWrite: readonly AgentReplayEvent[];
  readonly duplicateEventIds: readonly string[];
  readonly maxSeqBySession: ReadonlyMap<string, number>;
}

async function selectPendingEvents(
  events: readonly AgentReplayEvent[],
  dedup: KVNamespace,
): Promise<PendingEvents | Response> {
  const eventsToWrite: AgentReplayEvent[] = [];
  const duplicateEventIds: string[] = [];
  const seenEventIds = new Set<string>();
  const maxSeqBySession = new Map<string, number>();

  for (const event of events) {
    if (seenEventIds.has(event.eventId)) {
      duplicateEventIds.push(event.eventId);
      continue;
    }
    seenEventIds.add(event.eventId);

    if ((await dedup.get(eventKey(event.eventId))) !== null) {
      duplicateEventIds.push(event.eventId);
      continue;
    }

    let previousSeq = maxSeqBySession.get(event.sessionId);
    if (previousSeq === undefined) {
      const storedSeq = await dedup.get(lastSeqKey(event.sessionId));
      previousSeq = storedSeq === null ? -1 : Number(storedSeq);
      if (!Number.isFinite(previousSeq)) previousSeq = -1;
    }
    if (event.seq <= previousSeq) {
      return json({ error: "non_monotonic_agent_replay_seq", eventId: event.eventId }, 409);
    }

    maxSeqBySession.set(event.sessionId, event.seq);
    eventsToWrite.push(event);
  }

  return { eventsToWrite, duplicateEventIds, maxSeqBySession };
}

async function rememberAcceptedEvents(
  dedup: KVNamespace,
  events: readonly AgentReplayEvent[],
  maxSeqBySession: ReadonlyMap<string, number>,
): Promise<void> {
  const writes: Promise<unknown>[] = [];
  for (const event of events) {
    writes.push(dedup.put(eventKey(event.eventId), event.sessionId));
  }
  for (const [sessionId, seq] of maxSeqBySession.entries()) {
    writes.push(dedup.put(lastSeqKey(sessionId), String(seq)));
  }
  await Promise.all(writes);
}

function traceIdForSession(sessionId: string): string {
  return `agent-replay-${sessionId}`;
}

function langfuseEnvironment(env: Env): string | undefined {
  return optionalSecret(env.LANGFUSE_ENVIRONMENT) ?? undefined;
}

function langfuseBatch(
  events: readonly AgentReplayEvent[],
  env: Env,
): readonly LangfuseBatchItem[] {
  const batch: LangfuseBatchItem[] = [];
  const firstEventBySession = new Map<string, AgentReplayEvent>();

  for (const event of events) {
    if (!firstEventBySession.has(event.sessionId)) {
      firstEventBySession.set(event.sessionId, event);
    }
  }

  for (const event of firstEventBySession.values()) {
    batch.push({
      id: `trace-${traceIdForSession(event.sessionId)}`,
      timestamp: event.timestamp,
      type: "trace-create",
      body: {
        id: traceIdForSession(event.sessionId),
        name: "agent-replay",
        sessionId: event.sessionId,
        timestamp: event.timestamp,
        tags: ["agent-replay"],
        environment: langfuseEnvironment(env),
        metadata: {
          replay: true,
          retentionDays: DEFAULT_RETENTION_DAYS,
        },
      },
    });
  }

  for (const event of events) {
    batch.push({
      id: event.eventId,
      timestamp: event.timestamp,
      type: "event-create",
      body: {
        id: event.eventId,
        traceId: traceIdForSession(event.sessionId),
        name: event.type,
        startTime: event.timestamp,
        input: event.payload,
        level: event.type === "loop_failed" ? "ERROR" : "DEFAULT",
        metadata: {
          replay: true,
          sessionId: event.sessionId,
          seq: event.seq,
          eventId: event.eventId,
          type: event.type,
          retentionDays: DEFAULT_RETENTION_DAYS,
        },
      },
    });
  }

  return batch;
}

function readLangfuseBaseUrl(env: Env): string | Response {
  const raw = optionalSecret(env.LANGFUSE_BASE_URL) ?? DEFAULT_LANGFUSE_BASE_URL;
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:" || url.search !== "" || url.hash !== "") {
      return json({ error: "langfuse_base_url_invalid" }, 500);
    }
    return url.href.replace(/\/$/, "");
  } catch {
    return json({ error: "langfuse_base_url_invalid" }, 500);
  }
}

async function writeLangfuse(
  events: readonly AgentReplayEvent[],
  env: Env,
): Promise<Response | null> {
  const publicKey = readSecret(env.LANGFUSE_PUBLIC_KEY, "LANGFUSE_PUBLIC_KEY");
  if (publicKey instanceof Response) return publicKey;
  const secretKey = readSecret(env.LANGFUSE_SECRET_KEY, "LANGFUSE_SECRET_KEY");
  if (secretKey instanceof Response) return secretKey;
  const baseUrl = readLangfuseBaseUrl(env);
  if (baseUrl instanceof Response) return baseUrl;

  const response = await fetch(`${baseUrl}/api/public/ingestion`, {
    method: "POST",
    headers: {
      authorization: `Basic ${btoa(`${publicKey}:${secretKey}`)}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      batch: langfuseBatch(events, env),
      metadata: {
        source: "director-agent-replay",
        retentionDays: DEFAULT_RETENTION_DAYS,
      },
    }),
  });

  if (!response.ok) return json({ error: "langfuse_replay_write_failed" }, 502);
  return null;
}

async function writeReplay(
  events: readonly AgentReplayEvent[],
  env: Env,
): Promise<Response | null> {
  if (events.length === 0) return null;
  if (env.AGENT_REPLAY_TEST_SINK !== undefined) {
    await env.AGENT_REPLAY_TEST_SINK.append(events);
    return null;
  }
  return writeLangfuse(events, env);
}

async function handleReplayRequest(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return Response.json(
      { error: "method_not_allowed" },
      { status: 405, headers: { allow: "POST", "cache-control": "no-store" } },
    );
  }

  const authFailure = authenticate(request, env);
  if (authFailure !== null) return authFailure;

  let rawBody: ReplayRequestBody;
  try {
    rawBody = (await request.json()) as ReplayRequestBody;
  } catch {
    return json({ error: "invalid_agent_replay_request" }, 400);
  }

  const events = parseReplayRequest(rawBody);
  if (events instanceof Response) return events;

  const dedup = readDedupStore(env);
  if (dedup instanceof Response) return dedup;

  const pending = await selectPendingEvents(events, dedup);
  if (pending instanceof Response) return pending;

  const writeFailure = await writeReplay(pending.eventsToWrite, env);
  if (writeFailure !== null) return writeFailure;

  await rememberAcceptedEvents(dedup, pending.eventsToWrite, pending.maxSeqBySession);
  return json({
    accepted: pending.eventsToWrite.map((event) => ({
      eventId: event.eventId,
      sessionId: event.sessionId,
      seq: event.seq,
    })),
    duplicateEventIds: pending.duplicateEventIds,
  });
}

async function handleTestSinkRequest(
  request: Request,
  env: Env,
  sessionId: string,
): Promise<Response> {
  if (request.method !== "GET") {
    return Response.json(
      { error: "method_not_allowed" },
      { status: 405, headers: { allow: "GET", "cache-control": "no-store" } },
    );
  }

  const authFailure = authenticate(request, env);
  if (authFailure !== null) return authFailure;

  const sink = env.AGENT_REPLAY_TEST_SINK;
  if (sink === undefined) return json({ error: "not_found" }, 404);
  return json({ records: await sink.records(sessionId) });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === REPLAY_EVENTS_PATH) return handleReplayRequest(request, env);
    if (url.pathname.startsWith(TEST_SINK_PATH_PREFIX)) {
      const sessionId = decodeURIComponent(url.pathname.slice(TEST_SINK_PATH_PREFIX.length));
      if (sessionId === "") return json({ error: "not_found" }, 404);
      return handleTestSinkRequest(request, env, sessionId);
    }
    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
