import { describe, expect, it } from "vitest";

import { DEFAULT_LOCAL_CONFIG, safeParseLocalConfig } from "./config";

describe("local config contract", () => {
  it("accepts the default non-secret preferences", () => {
    const result = safeParseLocalConfig(DEFAULT_LOCAL_CONFIG);
    expect(result.success).toBe(true);
  });

  it("accepts a mock STT provider with demo mode enabled", () => {
    const result = safeParseLocalConfig({ sttProvider: "mock", demoMode: true });
    expect(result.success).toBe(true);
  });

  it("rejects unknown STT providers before they cross the UI boundary", () => {
    const result = safeParseLocalConfig({ sttProvider: "ambient", demoMode: false });
    expect(result.success).toBe(false);
  });

  it("rejects malformed demo mode values", () => {
    const result = safeParseLocalConfig({ sttProvider: "assemblyai", demoMode: "yes" });
    expect(result.success).toBe(false);
  });
});
