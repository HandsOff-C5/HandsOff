import { afterEach, describe, expect, it, vi } from "vitest";

import worker, { type AgentReplayEvent, type Env, type ReplayTestSink } from "./index";

class MemoryKv {
  private readonly values = new Map<string, string>();

  async get(key: string): Promise<string | null> {
    return this.values.get(key) ?? null;
  }

  async put(key: string, value: string): Promise<void> {
    this.values.set(key, value);
  }
}

class MemoryReplaySink implements ReplayTestSink {
  private readonly written: AgentReplayEvent[] = [];

  async append(events: readonly AgentReplayEvent[]): Promise<void> {
    this.written.push(...events);
  }

  async records(sessionId: string): Promise<readonly AgentReplayEvent[]> {
    return this.written.filter((event) => event.sessionId === sessionId);
  }
}

function kv(): KVNamespace {
  return new MemoryKv() as unknown as KVNamespace;
}

function env(overrides: Partial<Env> = {}): Env {
  return {
    HANDSOFF_APP_TOKEN: "app-token",
    AGENT_REPLAY_DEDUP: kv(),
    AGENT_REPLAY_TEST_SINK: new MemoryReplaySink(),
    ...overrides,
  };
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

const timestamp = "2026-06-27T15:00:00.000Z";

function event(seq: number, type: AgentReplayEvent["type"], payload: unknown): AgentReplayEvent {
  return {
    sessionId: "session-1",
    seq,
    eventId: `session-1:${seq}:${type}`,
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
    expect((init?.headers as Record<string, string>).authorization).toBe(
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
