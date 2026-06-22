import { describe, expect, it, vi } from "vitest";

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

describe("assemblyai token Worker", () => {
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
    upstreamFetch.mockRestore();
  });
});
