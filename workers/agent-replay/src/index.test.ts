import { afterEach, describe, expect, it, vi } from "vitest";

import worker, {
  AgentReplaySession,
  type AgentReplayEvent,
  type Env,
  type ReplayTestSink,
} from "./index";

class MemoryReplaySink implements ReplayTestSink {
  private readonly written: AgentReplayEvent[] = [];

  async append(events: readonly AgentReplayEvent[]): Promise<void> {
    this.written.push(...events);
  }

  async records(sessionId: string): Promise<readonly AgentReplayEvent[]> {
    return this.written.filter((event) => event.sessionId === sessionId);
  }
}

class MemoryDurableObjectStorage {
  private values = new Map<string, unknown>();
  private alarm: number | null = null;

  constructor(private readonly failPut = false) {}

  async get<T>(key: string): Promise<T | undefined> {
    return this.values.get(key) as T | undefined;
  }

  async put(entries: Record<string, unknown>): Promise<void> {
    if (this.failPut) throw new Error("put failed");
    for (const [key, value] of Object.entries(entries)) this.values.set(key, value);
  }

  async delete(keys: string | string[]): Promise<void> {
    for (const key of Array.isArray(keys) ? keys : [keys]) this.values.delete(key);
  }

  async setAlarm(scheduledTime: number | Date): Promise<void> {
    this.alarm = Number(scheduledTime);
  }

  async deleteAll(): Promise<void> {
    this.values.clear();
    this.alarm = null;
  }
}

class MemoryReplaySessionNamespace {
  private readonly sessions = new Map<string, AgentReplaySession>();

  constructor(
    private readonly replayEnv: Env,
    private readonly options: { failPut?: boolean } = {},
  ) {}

  idFromName(name: string): DurableObjectId {
    return { name, equals: (other) => other.name === name, toString: () => name };
  }

  get(id: DurableObjectId): DurableObjectStub {
    const sessionId = id.name ?? id.toString();
    let session = this.sessions.get(sessionId);
    if (session === undefined) {
      session = new AgentReplaySession(
        {
          storage: new MemoryDurableObjectStorage(this.options.failPut),
        } as unknown as DurableObjectState,
        this.replayEnv,
      );
      this.sessions.set(sessionId, session);
    }
    return session as unknown as DurableObjectStub;
  }
}

function env(overrides: Partial<Env> = {}): Env {
  const replayEnv = {
    HANDSOFF_APP_TOKEN: "app-token",
    AGENT_REPLAY_TEST_SINK: new MemoryReplaySink(),
    ...overrides,
  } as Env;
  if (overrides.AGENT_REPLAY_SESSIONS === undefined) {
    (replayEnv as { AGENT_REPLAY_SESSIONS: DurableObjectNamespace }).AGENT_REPLAY_SESSIONS =
      new MemoryReplaySessionNamespace(replayEnv) as unknown as DurableObjectNamespace;
  }
  return replayEnv;
}

function replayRequest(
  body: unknown,
  headers: HeadersInit = { Authorization: "Bearer app-token" },
) {
  return new Request("https://replay.handsoff.test/v1/agent-replay/events", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

function testSinkRequest(
  sessionId: string,
  headers: HeadersInit = { Authorization: "Bearer app-token" },
) {
  return new Request(`https://replay.handsoff.test/v1/agent-replay/test-sink/${sessionId}`, {
    headers,
  });
}

function headerValue(headers: HeadersInit | undefined, name: string): string | null {
  return new Headers(headers).get(name);
}

type ReplayResponseBody = {
  readonly accepted: readonly {
    readonly eventId: string;
    readonly sessionId: string;
    readonly seq: number;
  }[];
  readonly duplicateEventIds: readonly string[];
  readonly errors?: readonly unknown[];
};

const timestamp = "2026-06-27T15:00:00.000Z";

function event(
  seq: number,
  type: AgentReplayEvent["type"],
  payload: unknown,
  sessionId = "session-1",
): AgentReplayEvent {
  return {
    sessionId,
    seq,
    eventId: `${sessionId}:${seq}:${type}`,
    type,
    timestamp,
    payload,
  };
}

const representativeEvents: AgentReplayEvent[] = [
  event(0, "session_started", { goal: "Send the status email" }),
  event(1, "transcript_final", {
    transcript: "Tell Pat the build failed after the compile step",
    confidence: 0.93,
  }),
  event(2, "prompt_built", {
    messages: [
      { role: "system", content: "Resolve the next safe computer-use step." },
      { role: "user", content: "Tell Pat the build failed after the compile step" },
    ],
    intentSchema: { name: "next_tool_call", required: ["status"] },
  }),
  event(3, "model_response", {
    response: {
      status: "needs_approval",
      tool: "click",
      args: { x: 412, y: 688 },
      rationale: "The send button is visible.",
    },
  }),
  event(4, "intent_resolved", { status: "needs_approval", tool: "click" }),
  event(5, "approval_decided", { decision: "approved" }),
  event(6, "tool_call_started", { tool: "click", args: { x: 412, y: 688 } }),
  event(7, "tool_call_finished", {
    tool: "click",
    result: { ok: true, summary: "Clicked Send" },
    durationMs: 42,
  }),
  event(8, "loop_finished", { status: "completed", finalResponse: "Clicked Send" }),
];

describe("agent replay Worker", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("rejects a missing app credential", async () => {
    const response = await worker.fetch(replayRequest({ events: representativeEvents }, {}), env());

    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toEqual({ error: "missing_app_credential" });
  });

  it("writes ordered replay events to the authenticated test sink path", async () => {
    const replayEnv = env();
    const response = await worker.fetch(replayRequest({ events: representativeEvents }), replayEnv);

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      accepted: representativeEvents.map((item) => ({
        eventId: item.eventId,
        sessionId: item.sessionId,
        seq: item.seq,
      })),
      duplicateEventIds: [],
    });

    const sinkResponse = await worker.fetch(testSinkRequest("session-1"), replayEnv);
    expect(sinkResponse.status).toBe(200);
    await expect(sinkResponse.json()).resolves.toEqual({ records: representativeEvents });
  });

  it("deduplicates a repeated eventId without writing a second record", async () => {
    const replayEnv = env();
    const first = representativeEvents[0]!;

    expect((await worker.fetch(replayRequest({ events: [first] }), replayEnv)).status).toBe(200);
    const response = await worker.fetch(replayRequest({ events: [first] }), replayEnv);

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      accepted: [],
      duplicateEventIds: [first.eventId],
    });

    const sinkResponse = await worker.fetch(testSinkRequest("session-1"), replayEnv);
    await expect(sinkResponse.json()).resolves.toEqual({ records: [first] });
  });

  it("serializes concurrent duplicate eventIds through the session coordinator", async () => {
    const replayEnv = env();
    const first = representativeEvents[0]!;

    const responses = await Promise.all([
      worker.fetch(replayRequest({ events: [first] }), replayEnv),
      worker.fetch(replayRequest({ events: [first] }), replayEnv),
    ]);
    const bodies = await Promise.all(
      responses.map(async (response) => (await response.json()) as ReplayResponseBody),
    );

    expect(responses.map((response) => response.status)).toEqual([200, 200]);
    expect(bodies.flatMap((body) => body.accepted)).toEqual([
      { eventId: first.eventId, sessionId: first.sessionId, seq: first.seq },
    ]);
    expect(bodies.flatMap((body) => body.duplicateEventIds)).toEqual([first.eventId]);

    const sinkResponse = await worker.fetch(testSinkRequest("session-1"), replayEnv);
    await expect(sinkResponse.json()).resolves.toEqual({ records: [first] });
  });

  it("rejects excluded credential-like replay payload fields before writing", async () => {
    const replayEnv = env();
    const response = await worker.fetch(
      replayRequest({
        events: [
          event(0, "tool_call_started", {
            tool: "navigate",
            args: { bearerToken: "should-never-cross-the-wire" },
          }),
        ],
      }),
      replayEnv,
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({
      error: "forbidden_agent_replay_payload",
      index: 0,
      path: "payload.args.bearerToken",
    });

    const sinkResponse = await worker.fetch(testSinkRequest("session-1"), replayEnv);
    await expect(sinkResponse.json()).resolves.toEqual({ records: [] });
  });

  it("rejects out-of-order seq values for new events in a session", async () => {
    const replayEnv = env();
    const first = event(1, "transcript_final", { transcript: "hello" });
    expect((await worker.fetch(replayRequest({ events: [first] }), replayEnv)).status).toBe(200);

    const response = await worker.fetch(
      replayRequest({
        events: [
          {
            ...event(1, "prompt_built", { messages: [] }),
            eventId: "session-1:1:prompt_built-different",
          },
        ],
      }),
      replayEnv,
    );

    expect(response.status).toBe(409);
    await expect(response.json()).resolves.toEqual({
      error: "non_monotonic_agent_replay_seq",
      eventId: "session-1:1:prompt_built-different",
    });
  });

  it("does not burn replay state when the downstream write fails", async () => {
    const upstreamFetch = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(new Response("nope", { status: 502 }))
      .mockResolvedValueOnce(new Response("{}"));
    const replayEnv = env({
      AGENT_REPLAY_TEST_SINK: undefined,
      LANGFUSE_PUBLIC_KEY: "public-key",
      LANGFUSE_SECRET_KEY: "secret-key",
      LANGFUSE_BASE_URL: "https://langfuse.test",
    });
    const first = representativeEvents[0]!;

    const failed = await worker.fetch(replayRequest({ events: [first] }), replayEnv);
    expect(failed.status).toBe(502);
    await expect(failed.json()).resolves.toEqual({ error: "langfuse_replay_write_failed" });

    const retry = await worker.fetch(replayRequest({ events: [first] }), replayEnv);
    expect(retry.status).toBe(200);
    await expect(retry.json()).resolves.toEqual({
      accepted: [{ eventId: first.eventId, sessionId: first.sessionId, seq: first.seq }],
      duplicateEventIds: [],
    });
    expect(upstreamFetch).toHaveBeenCalledTimes(2);
  });

  it("does not send downstream when replay state cannot be committed", async () => {
    const sink = new MemoryReplaySink();
    const replayEnv = env({ AGENT_REPLAY_TEST_SINK: sink });
    (replayEnv as { AGENT_REPLAY_SESSIONS: DurableObjectNamespace }).AGENT_REPLAY_SESSIONS =
      new MemoryReplaySessionNamespace(replayEnv, {
        failPut: true,
      }) as unknown as DurableObjectNamespace;
    const first = representativeEvents[0]!;

    const response = await worker.fetch(replayRequest({ events: [first] }), replayEnv);

    expect(response.status).toBe(500);
    await expect(response.json()).resolves.toEqual({ error: "agent_replay_state_commit_failed" });
    await expect(sink.records("session-1")).resolves.toEqual([]);
  });

  it("returns committed session acks when a mixed-session batch has a bad session", async () => {
    const replayEnv = env();
    const accepted = event(0, "session_started", { goal: "ok" }, "session-1");
    const badFirst = event(0, "session_started", { goal: "bad" }, "session-2");
    const badSecond = {
      ...event(0, "prompt_built", { messages: [] }, "session-2"),
      eventId: "session-2:0:prompt_built-different",
    };

    const response = await worker.fetch(
      replayRequest({ events: [accepted, badFirst, badSecond] }),
      replayEnv,
    );
    const body = (await response.json()) as ReplayResponseBody;

    expect(response.status).toBe(207);
    expect(body.accepted).toEqual([
      { eventId: accepted.eventId, sessionId: accepted.sessionId, seq: accepted.seq },
    ]);
    expect(body.duplicateEventIds).toEqual([]);
    expect(body.errors).toEqual([
      {
        sessionId: "session-2",
        status: 409,
        body: {
          error: "non_monotonic_agent_replay_seq",
          eventId: "session-2:0:prompt_built-different",
        },
      },
    ]);
    await expect(
      (await worker.fetch(testSinkRequest("session-1"), replayEnv)).json(),
    ).resolves.toEqual({
      records: [accepted],
    });
    await expect(
      (await worker.fetch(testSinkRequest("session-2"), replayEnv)).json(),
    ).resolves.toEqual({
      records: [],
    });
  });

  it("writes replay records to Langfuse ingestion with stable trace and event ids", async () => {
    const upstreamFetch = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(new Response("{}"));
    const replayEnv = env({
      AGENT_REPLAY_TEST_SINK: undefined,
      LANGFUSE_PUBLIC_KEY: "public-key",
      LANGFUSE_SECRET_KEY: "secret-key",
      LANGFUSE_BASE_URL: "https://langfuse.test",
    });
    const failed = {
      ...event(1, "loop_failed", {
        status: "failed",
        errorClass: "tool_timeout",
        finalResponse: "The click did not complete.",
      }),
      eventId: "session-1:1:loop_failed",
    } satisfies AgentReplayEvent;

    const response = await worker.fetch(
      replayRequest({ events: [representativeEvents[0], failed] }),
      replayEnv,
    );

    expect(response.status).toBe(200);
    expect(upstreamFetch).toHaveBeenCalledTimes(1);
    const [url, init] = upstreamFetch.mock.calls[0]!;
    expect(url).toBe("https://langfuse.test/api/public/ingestion");
    expect(init).toMatchObject({ method: "POST" });
    expect(headerValue(init?.headers as HeadersInit, "authorization")).toBe(
      `Basic ${btoa("public-key:secret-key")}`,
    );
    expect(JSON.parse(String(init?.body))).toEqual({
      batch: [
        {
          id: "trace-agent-replay-session-1",
          timestamp,
          type: "trace-create",
          body: {
            id: "agent-replay-session-1",
            name: "agent-replay",
            sessionId: "session-1",
            timestamp,
            tags: ["agent-replay"],
            metadata: {
              replay: true,
              retentionDays: 30,
            },
          },
        },
        {
          id: "session-1:0:session_started",
          timestamp,
          type: "event-create",
          body: {
            id: "session-1:0:session_started",
            traceId: "agent-replay-session-1",
            name: "session_started",
            startTime: timestamp,
            input: { goal: "Send the status email" },
            level: "DEFAULT",
            metadata: {
              replay: true,
              sessionId: "session-1",
              seq: 0,
              eventId: "session-1:0:session_started",
              type: "session_started",
              retentionDays: 30,
            },
          },
        },
        {
          id: "session-1:1:loop_failed",
          timestamp,
          type: "event-create",
          body: {
            id: "session-1:1:loop_failed",
            traceId: "agent-replay-session-1",
            name: "loop_failed",
            startTime: timestamp,
            input: {
              status: "failed",
              errorClass: "tool_timeout",
              finalResponse: "The click did not complete.",
            },
            level: "ERROR",
            metadata: {
              replay: true,
              sessionId: "session-1",
              seq: 1,
              eventId: "session-1:1:loop_failed",
              type: "loop_failed",
              retentionDays: 30,
            },
          },
        },
      ],
      metadata: {
        source: "director-agent-replay",
        retentionDays: 30,
      },
    });
  });
});
