import { request as httpsRequest } from "node:https";

import { resolveNextToolCall, type ResolveNextToolCallOptions } from "@handsoff/intent";

import type { NextToolCallResolver } from "../intentResolver";

// A live worker-HTTP NextToolCallResolver for the e2e harness.
//
// It is the Node-side mirror of `createIntentWorkerResolver` (intentResolver.ts)
// crossed with the Rust `intent_resolve` command: where the app posts the
// {model, messages} request to the CF Worker through a Tauri `invoke`, this
// posts it over real HTTPS to HANDSOFF_INTENT_WORKER_URL with the
// `Authorization: Bearer <HANDSOFF_INTENT_APP_AUTH_TOKEN>` header, and returns
// the worker's JSON body verbatim ({ choices: [...] }). The worker structures
// the OpenAI completion with the same `nextToolCallSchema`, so the choice's
// `message.parsed` is exactly what `resolveNextToolCall` reads. Running this
// exercises the REAL worker + REAL OpenAI, not a fake.
//
// The URL + token are read from the environment (the harness is run with
// apps/desktop/.env.local sourced); a missing one throws loudly so the live run
// fails fast rather than silently degrading.

interface WorkerHttpConfig {
  readonly url: string;
  readonly token: string;
}

function readConfig(): WorkerHttpConfig {
  const url = process.env.HANDSOFF_INTENT_WORKER_URL?.trim();
  const token = process.env.HANDSOFF_INTENT_APP_AUTH_TOKEN?.trim();
  if (!url) {
    throw new Error("HANDSOFF_INTENT_WORKER_URL is not set — source apps/desktop/.env.local");
  }
  if (!token) {
    throw new Error("HANDSOFF_INTENT_APP_AUTH_TOKEN is not set — source apps/desktop/.env.local");
  }
  return { url, token };
}

// POST the {model, messages} body to the worker and resolve with its parsed
// JSON response. Rejects on a non-2xx status (carrying the body) or a transport
// error, so a worker/auth failure surfaces in the test rather than being read as
// "no choices".
function postIntent(config: WorkerHttpConfig, body: unknown): Promise<unknown> {
  const payload = JSON.stringify(body);
  const target = new URL(config.url);
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      {
        method: "POST",
        hostname: target.hostname,
        path: target.pathname,
        port: target.port || 443,
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(payload),
          Authorization: `Bearer ${config.token}`,
        },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          const status = res.statusCode ?? 0;
          if (status < 200 || status >= 300) {
            reject(new Error(`Worker intent request failed (${status}): ${text}`));
            return;
          }
          try {
            resolve(JSON.parse(text));
          } catch (caught) {
            reject(
              new Error(
                `Worker intent response was not JSON: ${caught instanceof Error ? caught.message : String(caught)}`,
              ),
            );
          }
        });
      },
    );
    req.on("error", reject);
    req.write(payload);
    req.end();
  });
}

// Build a NextToolCallResolver that routes the model call through the live
// worker. Shaped exactly like createIntentWorkerResolver: it supplies a minimal
// `client.chat.completions.parse` that posts {model, messages} and returns the
// worker's `{ choices }`, then delegates to the real resolveNextToolCall so the
// prompt building, tool validation, and ResolvedIntent mapping are all the real
// production code path.
export function createWorkerHttpResolver(): NextToolCallResolver {
  const config = readConfig();
  return (input, options) => {
    const client: NonNullable<ResolveNextToolCallOptions["client"]> = {
      chat: {
        completions: {
          async parse(rawRequest) {
            const { model, messages } = rawRequest as { model?: unknown; messages?: unknown };
            const response = await postIntent(config, { model, messages });
            return response as Awaited<
              ReturnType<
                NonNullable<ResolveNextToolCallOptions["client"]>["chat"]["completions"]["parse"]
              >
            >;
          },
        },
      },
    };
    return resolveNextToolCall(input, { ...options, client });
  };
}
