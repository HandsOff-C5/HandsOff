import { afterEach, describe, expect, it, vi } from "vitest";

import {
  ObservabilityMemorySink,
  safeParseObservabilityRecord,
  type ObservabilityRecord,
} from "@handsoff/contracts";

import worker, { __test, type Env } from "./index";

const env: Env = {
  OPENAI_API_KEY: "openai-key",
  GEMINI_API_KEY: "gemini-key",
  HANDSOFF_APP_TOKEN: "app-token",
};

const messages = [
  { role: "system", content: "You are HandsOff's autonomous computer-use agent." },
  { role: "user", content: JSON.stringify({ goal: "click there" }) },
];

function request(init: { headers?: HeadersInit; body?: unknown; method?: string } = {}) {
  return new Request("https://intent.handsoff.test/v1/resolve-intent", {
    method: init.method ?? "POST",
    headers: init.headers,
    body:
      init.body === undefined
        ? JSON.stringify({ model: "gpt-4o-mini", messages })
        : JSON.stringify(init.body),
  });
}

function observedEnv(overrides: Partial<Env> = {}) {
  const sink = new ObservabilityMemorySink();
  return {
    env: { ...env, ...overrides, OBSERVABILITY_SINK: sink } as Env & {
      OBSERVABILITY_SINK: ObservabilityMemorySink;
    },
    sink,
  };
}

function observedHeaders() {
  return {
    Authorization: "Bearer app-token",
    "x-request-id": "req-intent-1",
    "x-correlation-id": "corr-intent-1",
    "x-handsoff-session-id": "session-intent-1",
    "x-handsoff-span-id": "span-intent-1",
    traceparent: "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01",
  };
}

function expectValidRecords(records: ObservabilityRecord[]) {
  expect(records.map((record) => safeParseObservabilityRecord(record).success)).toEqual(
    records.map(() => true),
  );
}

function providerResponse(model = "gpt-4o-mini") {
  return {
    id: "chatcmpl-test",
    object: "chat.completion",
    created: 1,
    model,
    choices: [
      {
        index: 0,
        finish_reason: "stop",
        message: {
          role: "assistant",
          content: JSON.stringify({
            status: "blocked",
            tool: null,
            args: null,
            rationale: "No clear target",
            summary: null,
            reason: "Need a clearer target",
          }),
          refusal: null,
        },
      },
    ],
  };
}

describe("llm intent Worker", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("rejects a missing app credential", async () => {
    const response = await worker.fetch(request(), env);

    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toEqual({ error: "missing_app_credential" });
  });

  it("rejects an invalid app credential", async () => {
    const response = await worker.fetch(
      request({ headers: { Authorization: "Bearer wrong" } }),
      env,
    );

    expect(response.status).toBe(403);
    await expect(response.json()).resolves.toEqual({ error: "invalid_app_credential" });
  });

  it("returns structured OpenAI choices for an authenticated app", async () => {
    const upstreamFetch = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify(providerResponse()), {
        headers: { "content-type": "application/json" },
      }),
    );

    const response = await worker.fetch(
      request({ headers: { Authorization: "Bearer app-token" } }),
      env,
    );

    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body).toMatchObject({
      choices: [
        {
          finish_reason: "stop",
          message: {
            parsed: {
              status: "blocked",
              reason: "Need a clearer target",
            },
          },
        },
      ],
    });
    const [url, init] = upstreamFetch.mock.calls[0]!;
    expect(url).toBe("https://api.openai.com/v1/chat/completions");
    expect(init).toMatchObject({ method: "POST" });
    expect((init?.headers as Headers).get("authorization")).toBe("Bearer openai-key");
  });

  it("emits sanitized request observability records", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify(providerResponse()), {
        headers: { "content-type": "application/json" },
      }),
    );
    const observed = observedEnv();

    const response = await worker.fetch(request({ headers: observedHeaders() }), observed.env);

    expect(response.status).toBe(200);
    const records = observed.sink.records();
    expectValidRecords(records);
    expect(records).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "log",
          level: "info",
          component: "workers.llm-intent",
          event: "request_finished",
          sessionId: "session-intent-1",
          correlationId: "corr-intent-1",
          traceId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          spanId: "span-intent-1",
          attributes: expect.objectContaining({
            request_id: "req-intent-1",
            route: "/v1/resolve-intent",
            method: "POST",
            http_status: 200,
            status_class: "2xx",
          }),
        }),
        expect.objectContaining({
          kind: "span",
          status: "ok",
          component: "workers.llm-intent",
          event: "http.server.request",
          traceId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          spanId: "span-intent-1",
          attributes: expect.objectContaining({
            request_id: "req-intent-1",
            route: "/v1/resolve-intent",
            http_status: 200,
          }),
        }),
        expect.objectContaining({
          kind: "metric",
          name: "worker.request.latency_ms",
          component: "workers.llm-intent",
          event: "worker_request_latency",
          value: expect.any(Number),
          unit: "ms",
          attributes: expect.objectContaining({
            route: "/v1/resolve-intent",
            status_class: "2xx",
          }),
        }),
      ]),
    );
    const serialized = JSON.stringify(records);
    expect(serialized).not.toContain("click there");
    expect(serialized).not.toContain("app-token");
    expect(serialized).not.toContain("openai-key");
    expect(serialized).not.toContain("gemini-key");
    expect(
      records.find(
        (record) => record.kind === "metric" && record.name === "worker.request.latency_ms",
      )?.attributes,
    ).not.toHaveProperty("request_id");
  });

  it("uses Gemini when it is the configured provider", async () => {
    const upstreamFetch = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify(providerResponse("gemini-3.5-flash")), {
        headers: { "content-type": "application/json" },
      }),
    );

    const response = await worker.fetch(
      request({ headers: { Authorization: "Bearer app-token" } }),
      { GEMINI_API_KEY: "gemini-key", HANDSOFF_APP_TOKEN: "app-token" },
    );

    expect(response.status).toBe(200);
    const [url, init] = upstreamFetch.mock.calls[0]!;
    expect(url).toBe("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions");
    expect((init?.headers as Headers).get("authorization")).toBe("Bearer gemini-key");
    expect(JSON.parse(String(init?.body))).toMatchObject({ model: "gemini-3.5-flash" });
  });

  it("falls back to Gemini when the OpenAI key is rejected", async () => {
    const upstreamFetch = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ error: { message: "bad key" } }), {
          status: 401,
          headers: { "content-type": "application/json" },
        }),
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify(providerResponse("gemini-3.5-flash")), {
          headers: { "content-type": "application/json" },
        }),
      );

    const response = await worker.fetch(
      request({ headers: { Authorization: "Bearer app-token" } }),
      env,
    );

    expect(response.status).toBe(200);
    expect(upstreamFetch).toHaveBeenCalledTimes(2);
    expect(upstreamFetch.mock.calls[0]?.[0]).toBe("https://api.openai.com/v1/chat/completions");
    expect(upstreamFetch.mock.calls[1]?.[0]).toBe(
      "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
    );
    expect(JSON.parse(String(upstreamFetch.mock.calls[1]?.[1]?.body))).toMatchObject({
      model: "gemini-3.5-flash",
    });
  });

  it("rejects invalid request bodies before calling a provider", async () => {
    const upstreamFetch = vi.spyOn(globalThis, "fetch");

    const response = await worker.fetch(
      request({ headers: { Authorization: "Bearer app-token" }, body: { model: "gpt-4o-mini" } }),
      env,
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({ error: "invalid_intent_request" });
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("rejects provider failures without leaking provider details", async () => {
    vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ error: { message: "bad key" } }), {
          status: 401,
          headers: { "content-type": "application/json" },
        }),
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ error: { message: "bad key" } }), {
          status: 401,
          headers: { "content-type": "application/json" },
        }),
      );

    const response = await worker.fetch(
      request({ headers: { Authorization: "Bearer app-token" } }),
      env,
    );

    expect(response.status).toBe(502);
    await expect(response.json()).resolves.toEqual({ error: "intent_request_failed" });
  });

  it("emits a sanitized error record for provider failures", async () => {
    vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ error: { message: "bad key" } }), {
          status: 401,
          headers: { "content-type": "application/json" },
        }),
      )
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ error: { message: "bad key" } }), {
          status: 401,
          headers: { "content-type": "application/json" },
        }),
      );
    const observed = observedEnv();

    const response = await worker.fetch(request({ headers: observedHeaders() }), observed.env);

    expect(response.status).toBe(502);
    const records = observed.sink.records();
    expectValidRecords(records);
    expect(records).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "error",
          component: "workers.llm-intent",
          event: "request_failed",
          errorClass: "IntentRequestFailedError",
          handled: true,
          attributes: expect.objectContaining({
            request_id: "req-intent-1",
            route: "/v1/resolve-intent",
            http_status: 502,
            status_class: "5xx",
          }),
        }),
        expect.objectContaining({
          kind: "metric",
          name: "worker.request.error.count",
          value: 1,
          attributes: expect.objectContaining({
            route: "/v1/resolve-intent",
            status_class: "5xx",
            error_class: "IntentRequestFailedError",
          }),
        }),
      ]),
    );
    const serialized = JSON.stringify(records);
    expect(serialized).not.toContain("bad key");
    expect(serialized).not.toContain("openai-key");
    expect(serialized).not.toContain("gemini-key");
    expect(
      records.find(
        (record) => record.kind === "metric" && record.name === "worker.request.error.count",
      )?.attributes,
    ).not.toHaveProperty("request_id");
  });

  it("captures unexpected Worker failures without leaking raw details", async () => {
    const observed = observedEnv();

    const response = await __test.observeRequest(
      request({ headers: observedHeaders() }),
      observed.env,
      "/v1/resolve-intent",
      async () => {
        throw new Error("raw prompt app-token openai-key");
      },
    );

    expect(response.status).toBe(500);
    await expect(response.json()).resolves.toEqual({ error: "internal_server_error" });
    const records = observed.sink.records();
    expectValidRecords(records);
    expect(records).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "error",
          event: "request_failed",
          errorClass: "InternalServerError",
          handled: true,
          attributes: expect.objectContaining({
            route: "/v1/resolve-intent",
            http_status: 500,
            status_class: "5xx",
          }),
        }),
      ]),
    );
    const serialized = JSON.stringify(records);
    expect(serialized).not.toContain("raw prompt");
    expect(serialized).not.toContain("app-token");
    expect(serialized).not.toContain("openai-key");
  });

  it("keeps the user response stable when the observability sink fails", async () => {
    const response = await __test.observeRequest(
      request({ headers: observedHeaders() }),
      {
        ...env,
        OBSERVABILITY_SINK: {
          emit() {
            throw new Error("sink unavailable");
          },
        },
      },
      "/v1/resolve-intent",
      async () => jsonResponse({ ok: true }, 202),
    );

    expect(response.status).toBe(202);
    await expect(response.json()).resolves.toEqual({ ok: true });
  });
});

function jsonResponse(body: unknown, status = 200): Response {
  return Response.json(body, { status });
}
