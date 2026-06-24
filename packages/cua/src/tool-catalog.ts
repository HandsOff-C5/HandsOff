import type { CuaResult, DriverToolDefinition } from "@handsoff/contracts";

import type { CuaDriver } from "./driver";
import { cuaSucceeded } from "./driver";

// The function-definition shape the agentic loop hands to the model: one entry
// per driver tool, with the driver's own JSON Schema as `parameters`. A tool the
// driver could not describe falls back to an open object schema so it stays
// callable rather than being dropped.
export type ToolFunctionDefinition = {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
};

const EMPTY_PARAMETERS: Record<string, unknown> = { type: "object", properties: {} };

function toParameters(inputSchema: DriverToolDefinition["inputSchema"]): Record<string, unknown> {
  return inputSchema && typeof inputSchema === "object" && !Array.isArray(inputSchema)
    ? (inputSchema as Record<string, unknown>)
    : EMPTY_PARAMETERS;
}

function toFunctionDefinition(tool: DriverToolDefinition): ToolFunctionDefinition {
  return {
    name: tool.name,
    description: tool.description,
    parameters: toParameters(tool.inputSchema),
  };
}

export type ToolCatalog = {
  // The raw driver catalog, loaded once and cached. A failed load is not cached,
  // so a transient driver error can be retried on the next call.
  load(): Promise<CuaResult<readonly DriverToolDefinition[]>>;
  // The same catalog mapped to model-facing function definitions.
  functionDefinitions(): Promise<CuaResult<readonly ToolFunctionDefinition[]>>;
};

export function createToolCatalog(driver: CuaDriver): ToolCatalog {
  let cached: readonly DriverToolDefinition[] | null = null;

  async function load(): Promise<CuaResult<readonly DriverToolDefinition[]>> {
    if (cached) return cuaSucceeded(cached);
    const result = await driver.listTools();
    if (result.status === "succeeded") cached = result.value;
    return result;
  }

  return {
    load,
    async functionDefinitions(): Promise<CuaResult<readonly ToolFunctionDefinition[]>> {
      const result = await load();
      if (result.status !== "succeeded") return result;
      return cuaSucceeded(result.value.map(toFunctionDefinition));
    },
  };
}
