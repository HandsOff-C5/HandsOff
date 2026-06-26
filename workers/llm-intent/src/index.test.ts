import { afterEach, describe, expect, it, vi } from "vitest";

import worker, { type Env } from "./index";

const env: Env = {
  OPENAI_API_KEY: "openai-key",
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

function openAiResponse() {
  return {
    id: "chatcmpl-test",
    object: "chat.completion",
    created: 1,
    model: "gpt-4o-mini",
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
      new Response(JSON.stringify(openAiResponse()), {
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

  it("rejects invalid request bodies before calling OpenAI", async () => {
    const upstreamFetch = vi.spyOn(globalThis, "fetch");

    const response = await worker.fetch(
      request({ headers: { Authorization: "Bearer app-token" }, body: { model: "gpt-4o-mini" } }),
      env,
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({ error: "invalid_intent_request" });
    expect(upstreamFetch).not.toHaveBeenCalled();
  });

  it("rejects OpenAI failures without leaking provider details", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
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
    await expect(response.json()).resolves.toEqual({ error: "openai_intent_request_failed" });
  });
});
