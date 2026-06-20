import { describe, expect, it } from "vitest";

import { DEFAULT_LOCAL_CONFIG, safeParseLocalConfig } from "./config";

describe("local config contract", () => {
  it("accepts the default non-secret preferences", () => {
    const result = safeParseLocalConfig(DEFAULT_LOCAL_CONFIG);
    expect(result.success).toBe(true);
  });

  it("rejects unknown STT providers before they cross the UI boundary", () => {
    const result = safeParseLocalConfig({ sttProvider: "ambient" });
    expect(result.success).toBe(false);
  });

  it("rejects a missing STT provider", () => {
    const result = safeParseLocalConfig({});
    expect(result.success).toBe(false);
  });
});
