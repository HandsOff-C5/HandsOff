import { afterEach, describe, expect, it, vi } from "vitest";

import worker, { type Env } from "./index";

const env: Env = {
  OPENAI_API_KEY: "openai-key",
  GEMINI_API_KEY: "gemini-key",
  HANDSOFF_APP_TOKEN: "app-token",
};

const messages = [
  { role: "system", content: "You are HandsOff's autonomous computer-use agent." },
  { role: "user", content: JSON.stringify({ goal: "click there" }) },
];

// U5: a multimodal user turn — `content` is an OpenAI/Gemini array of parts (a text part plus an
// inline base64 image part). The Worker treats `messages` as opaque `unknown[]`, so this must be
// forwarded to the provider byte-for-byte (no reshaping of the content array).
const multimodalMessages = [
  { role: "system", content: "You are HandsOff's autonomous computer-use agent." },
  {
    role: "user",
    content: [
      { type: "text", text: JSON.stringify({ goal: "click there" }) },
      { type: "image_url", image_url: { url: "data:image/png;base64,iVBORw0KGgo=" } },
    ],
  },
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
      request({ headers: { Authorization: "Bearer app-token" }, body: { messages } }),
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
    // KD4: with no request/env override, the upgraded OpenAI default is used.
    expect(JSON.parse(String(init?.body))).toMatchObject({ model: "gpt-4o" });
  });

  it("forwards multimodal array-of-parts message content to the provider unchanged", async () => {
    const upstreamFetch = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify(providerResponse()), {
        headers: { "content-type": "application/json" },
      }),
    );

    const response = await worker.fetch(
      request({
        headers: { Authorization: "Bearer app-token" },
        body: { messages: multimodalMessages },
      }),
      env,
    );

    expect(response.status).toBe(200);
    const [url, init] = upstreamFetch.mock.calls[0]!;
    expect(url).toBe("https://api.openai.com/v1/chat/completions");
    // The content array (text + image_url) is forwarded to the provider verbatim — the Worker does
    // not flatten, reshape, or drop the inline image part.
    const forwarded = JSON.parse(String(init?.body));
    expect(forwarded.messages).toEqual(multimodalMessages);
  });

  it("honors the OPENAI_MODEL env override over the upgraded default", async () => {
    const upstreamFetch = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify(providerResponse("gpt-4.1")), {
        headers: { "content-type": "application/json" },
      }),
    );

    const response = await worker.fetch(
      request({ headers: { Authorization: "Bearer app-token" }, body: { messages } }),
      { ...env, OPENAI_MODEL: "gpt-4.1" },
    );

    expect(response.status).toBe(200);
    const [, init] = upstreamFetch.mock.calls[0]!;
    expect(JSON.parse(String(init?.body))).toMatchObject({ model: "gpt-4.1" });
  });

  it("uses Gemini when it is the configured provider", async () => {
    const upstreamFetch = vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify(providerResponse("gemini-3.5-pro")), {
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
    expect(JSON.parse(String(init?.body))).toMatchObject({ model: "gemini-3.5-pro" });
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
        new Response(JSON.stringify(providerResponse("gemini-3.5-pro")), {
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
      model: "gemini-3.5-pro",
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
});
