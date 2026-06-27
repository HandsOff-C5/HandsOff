import { afterEach, describe, expect, it, vi } from "vitest";

import {
  ObservabilityMemorySink,
  safeParseObservabilityRecord,
  type ObservabilityRecord,
} from "@handsoff/contracts";

import worker, { type Env } from "./index";

const env: Env = {
  ASSEMBLYAI_API_KEY: "assemblyai-key",
  HANDSOFF_APP_TOKEN: "app-token",
  ASSEMBLYAI_TOKEN_ENDPOINT: "https://streaming.assemblyai.com/v3/token",
};

function request(headers: HeadersInit = {}) {
  return new Request("https://token.handsoff.test/v1/realtime-token?expires_in_seconds=60", {
    headers,
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
    "x-request-id": "req-stt-token-1",
    "x-correlation-id": "corr-stt-token-1",
    "x-handsoff-session-id": "session-stt-token-1",
    "x-handsoff-span-id": "span-stt-token-1",
    traceparent: "00-cccccccccccccccccccccccccccccccc-dddddddddddddddd-01",
  };
}

function expectValidRecords(records: ObservabilityRecord[]) {
  expect(records.map((record) => safeParseObservabilityRecord(record).success)).toEqual(
    records.map(() => true),
  );
}

describe("assemblyai token Worker", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("rejects a missing app credential", async () => {
    const response = await worker.fetch(request(), env);

    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toEqual({ error: "missing_app_credential" });
  });

  it("rejects an invalid app credential", async () => {
    const response = await worker.fetch(request({ Authorization: "Bearer wrong" }), env);

    expect(response.status).toBe(403);
    await expect(response.json()).resolves.toEqual({ error: "invalid_app_credential" });
  });

  it("returns a short-lived AssemblyAI token for an authenticated app", async () => {
    const upstreamFetch = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify({ token: "stream-token", expires_in_seconds: 60 }), {
        headers: { "content-type": "application/json" },
      }),
    );

    const response = await worker.fetch(request({ Authorization: "Bearer app-token" }), env);

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      token: "stream-token",
      expiresInSeconds: 60,
    });
    expect(upstreamFetch).toHaveBeenCalledWith(
      "https://streaming.assemblyai.com/v3/token?expires_in_seconds=60",
      expect.objectContaining({
        headers: { Authorization: "assemblyai-key" },
      }),
    );
  });

  it("emits sanitized request observability records", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify({ token: "stream-token", expires_in_seconds: 60 }), {
        headers: { "content-type": "application/json" },
      }),
    );
    const observed = observedEnv();

    const response = await worker.fetch(request(observedHeaders()), observed.env);

    expect(response.status).toBe(200);
    const records = observed.sink.records();
    expectValidRecords(records);
    expect(records).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "log",
          level: "info",
          component: "workers.assemblyai-token",
          event: "request_finished",
          sessionId: "session-stt-token-1",
          correlationId: "corr-stt-token-1",
          traceId: "cccccccccccccccccccccccccccccccc",
          spanId: "span-stt-token-1",
          attributes: expect.objectContaining({
            request_id: "req-stt-token-1",
            route: "/v1/realtime-token",
            method: "GET",
            http_status: 200,
            status_class: "2xx",
          }),
        }),
        expect.objectContaining({
          kind: "span",
          status: "ok",
          component: "workers.assemblyai-token",
          event: "http.server.request",
          traceId: "cccccccccccccccccccccccccccccccc",
          spanId: "span-stt-token-1",
          attributes: expect.objectContaining({
            request_id: "req-stt-token-1",
            route: "/v1/realtime-token",
            http_status: 200,
          }),
        }),
        expect.objectContaining({
          kind: "metric",
          name: "worker.request.latency_ms",
          component: "workers.assemblyai-token",
          event: "worker_request_latency",
          value: expect.any(Number),
          unit: "ms",
          attributes: expect.objectContaining({
            route: "/v1/realtime-token",
            status_class: "2xx",
          }),
        }),
      ]),
    );
    const serialized = JSON.stringify(records);
    expect(serialized).not.toContain("stream-token");
    expect(serialized).not.toContain("app-token");
    expect(serialized).not.toContain("assemblyai-key");
    expect(
      records.find(
        (record) => record.kind === "metric" && record.name === "worker.request.latency_ms",
      )?.attributes,
    ).not.toHaveProperty("request_id");
  });

  it("rejects invalid token lifetimes without calling AssemblyAI", async () => {
    const upstreamFetch = vi.spyOn(globalThis, "fetch");

    const response = await worker.fetch(
      new Request("https://token.handsoff.test/v1/realtime-token?expires_in_seconds=0", {
        headers: { Authorization: "Bearer app-token" },
      }),
      env,
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({ error: "invalid_expires_in_seconds" });
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("rejects an unsafe AssemblyAI token endpoint before sending the provider key", async () => {
    const upstreamFetch = vi.spyOn(globalThis, "fetch");

    const response = await worker.fetch(request({ Authorization: "Bearer app-token" }), {
      ...env,
      ASSEMBLYAI_TOKEN_ENDPOINT: "http://streaming.assemblyai.test/v3/token",
    });

    expect(response.status).toBe(500);
    await expect(response.json()).resolves.toEqual({ error: "assemblyai_token_endpoint_invalid" });
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("rejects an invalid AssemblyAI token response", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify({ token: "", expires_in_seconds: 60 }), {
        headers: { "content-type": "application/json" },
      }),
    );

    const response = await worker.fetch(request({ Authorization: "Bearer app-token" }), env);

    expect(response.status).toBe(502);
    await expect(response.json()).resolves.toEqual({ error: "invalid_assemblyai_token_response" });
  });

  it("emits a sanitized error record for invalid provider responses", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify({ token: "leaky-stream-token", expires_in_seconds: 0 }), {
        headers: { "content-type": "application/json" },
      }),
    );
    const observed = observedEnv();

    const response = await worker.fetch(request(observedHeaders()), observed.env);

    expect(response.status).toBe(502);
    const records = observed.sink.records();
    expectValidRecords(records);
    expect(records).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "error",
          component: "workers.assemblyai-token",
          event: "request_failed",
          errorClass: "InvalidAssemblyAiTokenResponseError",
          handled: true,
          attributes: expect.objectContaining({
            request_id: "req-stt-token-1",
            route: "/v1/realtime-token",
            http_status: 502,
            status_class: "5xx",
          }),
        }),
        expect.objectContaining({
          kind: "metric",
          name: "worker.request.error.count",
          value: 1,
          attributes: expect.objectContaining({
            route: "/v1/realtime-token",
            status_class: "5xx",
            error_class: "InvalidAssemblyAiTokenResponseError",
          }),
        }),
      ]),
    );
    const serialized = JSON.stringify(records);
    expect(serialized).not.toContain("leaky-stream-token");
    expect(serialized).not.toContain("assemblyai-key");
    expect(
      records.find(
        (record) => record.kind === "metric" && record.name === "worker.request.error.count",
      )?.attributes,
    ).not.toHaveProperty("request_id");
  });
});
