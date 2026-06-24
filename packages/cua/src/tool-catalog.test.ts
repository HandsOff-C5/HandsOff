import type { CuaResult, CuaWindowState, DriverToolDefinition } from "@handsoff/contracts";
import { describe, expect, it, vi } from "vitest";

import { cuaFailed } from "./driver";
import { createFakeCuaDriver } from "./fake-driver";
import { createToolCatalog } from "./tool-catalog";

const state: CuaWindowState = {
  surface: {
    id: "notes:2",
    title: "Notes",
    app: "Notes",
    pid: 2,
    windowId: 20,
    availability: "available",
    accessStatus: "accessible",
  },
  capturedAt: "2026-06-24T00:00:00.000Z",
  elementCount: 0,
  elements: [],
};

const tools: readonly DriverToolDefinition[] = [
  {
    name: "get_screen_size",
    description: "Return the logical size of the main display in points.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "scroll",
    description: "Scroll the target pid's focused region.",
    inputSchema: {
      type: "object",
      required: ["pid", "direction"],
      properties: { pid: { type: "integer" }, direction: { type: "string" } },
    },
  },
];

describe("tool catalog", () => {
  it("maps the driver catalog to function definitions with the driver schema as parameters", async () => {
    const driver = createFakeCuaDriver({ state, tools });
    const catalog = createToolCatalog(driver);

    const result = await catalog.functionDefinitions();

    expect(result).toEqual({
      status: "succeeded",
      value: [
        {
          name: "get_screen_size",
          description: "Return the logical size of the main display in points.",
          parameters: { type: "object", properties: {} },
        },
        {
          name: "scroll",
          description: "Scroll the target pid's focused region.",
          parameters: {
            type: "object",
            required: ["pid", "direction"],
            properties: { pid: { type: "integer" }, direction: { type: "string" } },
          },
        },
      ],
    });
  });

  it("falls back to an empty object schema when a tool has no input schema", async () => {
    const driver = createFakeCuaDriver({
      state,
      tools: [{ name: "stop_recording", description: "Stop recording.", inputSchema: null }],
    });

    const result = await createToolCatalog(driver).functionDefinitions();

    expect(result).toEqual({
      status: "succeeded",
      value: [
        {
          name: "stop_recording",
          description: "Stop recording.",
          parameters: { type: "object", properties: {} },
        },
      ],
    });
  });

  it("loads once and reuses the cached catalog on subsequent calls", async () => {
    const driver = createFakeCuaDriver({ state, tools });
    const listTools = vi.spyOn(driver, "listTools");
    const catalog = createToolCatalog(driver);

    const first = await catalog.load();
    const second = await catalog.load();
    const defs = await catalog.functionDefinitions();

    expect(first).toEqual({ status: "succeeded", value: tools });
    expect(second).toEqual(first);
    expect(defs.status).toBe("succeeded");
    // Cached after the first successful load: the driver is queried exactly once.
    expect(listTools).toHaveBeenCalledTimes(1);
  });

  it("does not cache a failed load so a transient driver error is retryable", async () => {
    const driver = createFakeCuaDriver({ state, tools });
    const listTools = vi
      .spyOn(driver, "listTools")
      .mockResolvedValueOnce(
        cuaFailed("driver offline") as CuaResult<readonly DriverToolDefinition[]>,
      );
    const catalog = createToolCatalog(driver);

    const failed = await catalog.load();
    const recovered = await catalog.load();

    expect(failed).toEqual({ status: "failed", error: "driver offline" });
    expect(recovered).toEqual({ status: "succeeded", value: tools });
    expect(listTools).toHaveBeenCalledTimes(2);
  });
});
