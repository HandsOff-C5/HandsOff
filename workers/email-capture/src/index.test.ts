import { afterEach, describe, expect, it, vi } from "vitest";

import worker, { type Env } from "./index";

const env: Env = {
  SUPABASE_URL: "https://proj.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "service-key",
  LOOPS_API_KEY: "loops_test",
  HANDSOFF_APP_TOKEN: "app-token",
  LOOPS_TRANSACTIONAL_ID: "test-transactional-id",
  CONFIRM_BASE_URL: "https://forthedirector.com/confirmed",
};

function subscribe(body: unknown, headers: HeadersInit = {}): Request {
  return new Request("https://email.handsoff.test/v1/subscribe", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

const AUTH = { Authorization: "Bearer app-token" };

describe("email-capture Worker", () => {
  afterEach(() => vi.restoreAllMocks());

  it("404s unknown paths", async () => {
    const res = await worker.fetch(new Request("https://x/v1/nope"), env);
    expect(res.status).toBe(404);
  });

  it("rejects a missing app credential", async () => {
    const res = await worker.fetch(subscribe({ email: "a@b.com" }), env);
    expect(res.status).toBe(401);
    await expect(res.json()).resolves.toEqual({ error: "missing_app_credential" });
  });

  it("rejects an invalid app credential", async () => {
    const res = await worker.fetch(
      subscribe({ email: "a@b.com" }, { Authorization: "Bearer no" }),
      env,
    );
    expect(res.status).toBe(403);
  });

  it("rejects a malformed email without calling upstreams", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch");
    const res = await worker.fetch(subscribe({ email: "not-an-email" }, AUTH), env);
    expect(res.status).toBe(400);
    await expect(res.json()).resolves.toEqual({ error: "invalid_email" });
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("inserts a new subscriber and sends a confirmation", async () => {
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(
        new Response(JSON.stringify([{ confirmation_token: "tok-123", confirmed: false }]), {
          status: 201,
        }),
      )
      .mockResolvedValueOnce(new Response(JSON.stringify({ success: true }), { status: 200 }));

    const res = await worker.fetch(
      subscribe({ email: "New@Example.com", source: "desktop" }, AUTH),
      env,
    );

    expect(res.status).toBe(202);
    await expect(res.json()).resolves.toEqual({ status: "confirmation_sent" });

    // First call: Supabase insert with lowercased email.
    const [insertUrl, insertInit] = fetchSpy.mock.calls[0]!;
    expect(String(insertUrl)).toBe("https://proj.supabase.co/rest/v1/subscribers");
    expect(JSON.parse(String(insertInit?.body))).toEqual({
      email: "new@example.com",
      source: "desktop",
    });

    // Second call: Loops transactional with the token link as a data variable.
    const [loopsUrl, loopsInit] = fetchSpy.mock.calls[1]!;
    expect(String(loopsUrl)).toBe("https://app.loops.so/api/v1/transactional");
    const sent = JSON.parse(String(loopsInit?.body));
    expect(sent.email).toBe("new@example.com");
    expect(sent.transactionalId).toBe("test-transactional-id");
    expect(sent.dataVariables.confirmationUrl).toContain("token=tok-123");
  });

  it("treats an already-confirmed duplicate as success without sending", async () => {
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(new Response("conflict", { status: 409 }))
      .mockResolvedValueOnce(
        new Response(JSON.stringify([{ confirmation_token: "tok-x", confirmed: true }]), {
          status: 200,
        }),
      );

    const res = await worker.fetch(subscribe({ email: "dup@example.com" }, AUTH), env);
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ status: "already_confirmed" });
    expect(fetchSpy).toHaveBeenCalledTimes(2); // no Loops call
  });

  it("confirms via token", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValueOnce(
      new Response(JSON.stringify([{ id: "1" }]), { status: 200 }),
    );
    const res = await worker.fetch(
      new Request("https://x/v1/confirm?token=00000000-0000-4000-8000-000000000000"),
      env,
    );
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toEqual({ status: "confirmed" });
  });

  it("rejects a malformed confirm token", async () => {
    const res = await worker.fetch(new Request("https://x/v1/confirm?token=nope"), env);
    expect(res.status).toBe(400);
  });
});
