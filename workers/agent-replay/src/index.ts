const REPLAY_EVENTS_PATH = "/v1/agent-replay/events";
const TEST_SINK_PATH_PREFIX = "/v1/agent-replay/test-sink/";
const DEFAULT_LANGFUSE_BASE_URL = "https://cloud.langfuse.com";
const DEFAULT_RETENTION_DAYS = 30;
const RETENTION_MS = DEFAULT_RETENTION_DAYS * 24 * 60 * 60 * 1000;
const LAST_SEQ_KEY = "last_seq";
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
  readonly AGENT_REPLAY_SESSIONS: DurableObjectNamespace;
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

function readReplaySessions(env: Env): DurableObjectNamespace | Response {
  if (
    typeof env.AGENT_REPLAY_SESSIONS?.idFromName !== "function" ||
    typeof env.AGENT_REPLAY_SESSIONS.get !== "function"
  ) {
    return json({ error: "agent_replay_sessions_missing" }, 500);
  }
  return env.AGENT_REPLAY_SESSIONS;
}

function eventKey(eventId: string): string {
  return `event:${eventId}`;
}

interface PendingEvents {
  readonly eventsToWrite: readonly AgentReplayEvent[];
  readonly duplicateEventIds: readonly string[];
  readonly errors: readonly ReplaySessionError[];
}

interface ReplaySessionError {
  readonly sessionId: string;
  readonly status: number;
  readonly body: unknown;
}

interface ReplaySessionRequestBody {
  readonly events?: unknown;
}

function retentionExpiresAt(): number {
  return Date.now() + RETENTION_MS;
}

export class AgentReplaySession {
  private gate: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {}

  async fetch(request: Request): Promise<Response> {
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

    let rawBody: ReplaySessionRequestBody;
    try {
      rawBody = (await request.json()) as ReplaySessionRequestBody;
    } catch {
      return json({ error: "invalid_agent_replay_request" }, 400);
    }

    if (!isRecord(rawBody) || !Array.isArray(rawBody.events)) {
      return json({ error: "invalid_agent_replay_request" }, 400);
    }

    return this.runExclusive(() => this.acceptEvents(rawBody.events as AgentReplayEvent[]));
  }

  private runExclusive<T>(work: () => Promise<T>): Promise<T> {
    const result = this.gate.then(work, work);
    this.gate = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  private async acceptEvents(events: readonly AgentReplayEvent[]): Promise<Response> {
    const eventsToWrite: AgentReplayEvent[] = [];
    const duplicateEventIds: string[] = [];
    const seenEventIds = new Set<string>();
    const storedPreviousSeq = await this.state.storage.get<number>(LAST_SEQ_KEY);
    let previousSeq = storedPreviousSeq ?? -1;
    if (!Number.isFinite(previousSeq)) previousSeq = -1;

    for (const event of events) {
      if (seenEventIds.has(event.eventId)) {
        duplicateEventIds.push(event.eventId);
        continue;
      }
      seenEventIds.add(event.eventId);

      if ((await this.state.storage.get(eventKey(event.eventId))) !== undefined) {
        duplicateEventIds.push(event.eventId);
        continue;
      }

      if (event.seq <= previousSeq) {
        return json({ error: "non_monotonic_agent_replay_seq", eventId: event.eventId }, 409);
      }

      previousSeq = event.seq;
      eventsToWrite.push(event);
    }

    if (eventsToWrite.length > 0) {
      try {
        await this.rememberAcceptedEvents(eventsToWrite, previousSeq);
      } catch {
        return json({ error: "agent_replay_state_commit_failed" }, 500);
      }
    }

    const writeFailure = await writeReplay(eventsToWrite, this.env);
    if (writeFailure !== null) {
      if (eventsToWrite.length > 0) {
        await this.forgetAcceptedEvents(eventsToWrite, storedPreviousSeq);
      }
      return writeFailure;
    }

    return json({ eventsToWrite, duplicateEventIds, errors: [] });
  }

  private async rememberAcceptedEvents(
    events: readonly AgentReplayEvent[],
    lastSeq: number,
  ): Promise<void> {
    const writes: Record<string, string | number> = { [LAST_SEQ_KEY]: lastSeq };
    for (const event of events) {
      writes[eventKey(event.eventId)] = event.sessionId;
    }
    await this.state.storage.put(writes);
    await this.state.storage.setAlarm(retentionExpiresAt());
  }

  private async forgetAcceptedEvents(
    events: readonly AgentReplayEvent[],
    previousSeq: number | undefined,
  ): Promise<void> {
    const eventKeys = events.map((event) => eventKey(event.eventId));
    await this.state.storage.delete(eventKeys);
    if (previousSeq === undefined) {
      await this.state.storage.delete(LAST_SEQ_KEY);
    } else {
      await this.state.storage.put({ [LAST_SEQ_KEY]: previousSeq });
    }
  }

  async alarm(): Promise<void> {
    await this.state.storage.deleteAll();
  }
}

function eventsBySession(
  events: readonly AgentReplayEvent[],
): ReadonlyMap<string, readonly AgentReplayEvent[]> {
  const sessions = new Map<string, AgentReplayEvent[]>();
  for (const event of events) {
    const sessionEvents = sessions.get(event.sessionId) ?? [];
    sessionEvents.push(event);
    sessions.set(event.sessionId, sessionEvents);
  }
  return sessions;
}

async function selectPendingEvents(
  events: readonly AgentReplayEvent[],
  sessions: DurableObjectNamespace,
): Promise<PendingEvents | Response> {
  const eventsToWrite: AgentReplayEvent[] = [];
  const duplicateEventIds: string[] = [];
  const errors: ReplaySessionError[] = [];
  const seenEventIds = new Set<string>();
  const uniqueEvents: AgentReplayEvent[] = [];

  for (const event of events) {
    if (seenEventIds.has(event.eventId)) {
      duplicateEventIds.push(event.eventId);
      continue;
    }
    seenEventIds.add(event.eventId);
    uniqueEvents.push(event);
  }

  for (const [sessionId, sessionEvents] of eventsBySession(uniqueEvents).entries()) {
    const stub = sessions.get(sessions.idFromName(sessionId));
    const response = await stub.fetch(
      new Request("https://agent-replay.internal/session", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ events: sessionEvents }),
      }),
    );
    if (!response.ok) {
      errors.push({ sessionId, status: response.status, body: await readResponseBody(response) });
      continue;
    }

    const pending = (await response.json()) as PendingEvents;
    eventsToWrite.push(...pending.eventsToWrite);
    duplicateEventIds.push(...pending.duplicateEventIds);
  }

  return { eventsToWrite, duplicateEventIds, errors };
}

async function readResponseBody(response: Response): Promise<unknown> {
  try {
    return await response.json();
  } catch {
    return { error: "agent_replay_session_failed" };
  }
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

  const sessions = readReplaySessions(env);
  if (sessions instanceof Response) return sessions;

  const pending = await selectPendingEvents(events, sessions);
  if (pending instanceof Response) return pending;

  const accepted = pending.eventsToWrite.map((event) => ({
    eventId: event.eventId,
    sessionId: event.sessionId,
    seq: event.seq,
  }));
  if (
    pending.errors.length > 0 &&
    accepted.length === 0 &&
    pending.duplicateEventIds.length === 0
  ) {
    const first = pending.errors[0]!;
    return json(first.body, first.status);
  }

  return json(
    {
      accepted,
      duplicateEventIds: pending.duplicateEventIds,
      ...(pending.errors.length > 0 ? { errors: pending.errors } : {}),
    },
    pending.errors.length > 0 ? 207 : 200,
  );
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
