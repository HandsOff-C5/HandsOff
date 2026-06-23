import { describe, expect, it } from "vitest";

import { DEFAULT_LOCAL_CONFIG, safeParseLocalConfig } from "./config";

describe("local config contract", () => {
  it("accepts the default non-secret preferences", () => {
    const result = safeParseLocalConfig(DEFAULT_LOCAL_CONFIG);
    expect(result.success).toBe(true);
  });

  it("accepts custom transcription and head pointer preferences", () => {
    const config = {
      sttProvider: "assemblyai",
      headPointer: {
        movementMode: "relative",
        speed: 8,
        distanceToEdge: 0.25,
      },
    };

    const result = safeParseLocalConfig(config);

    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data).toEqual(config);
    }
  });

  it("rejects unknown STT providers before they cross the UI boundary", () => {
    const result = safeParseLocalConfig({
      ...DEFAULT_LOCAL_CONFIG,
      sttProvider: "ambient",
    });
    expect(result.success).toBe(false);
  });

  it("rejects unknown head pointer movement modes", () => {
    const result = safeParseLocalConfig({
      ...DEFAULT_LOCAL_CONFIG,
      headPointer: {
        ...DEFAULT_LOCAL_CONFIG.headPointer,
        movementMode: "orbit",
      },
    });
    expect(result.success).toBe(false);
  });

  it("rejects head pointer values outside the user-facing range", () => {
    expect(
      safeParseLocalConfig({
        ...DEFAULT_LOCAL_CONFIG,
        headPointer: { ...DEFAULT_LOCAL_CONFIG.headPointer, speed: 11 },
      }).success,
    ).toBe(false);
    expect(
      safeParseLocalConfig({
        ...DEFAULT_LOCAL_CONFIG,
        headPointer: { ...DEFAULT_LOCAL_CONFIG.headPointer, distanceToEdge: 0.5 },
      }).success,
    ).toBe(false);
  });

  it("rejects old stored configs missing head pointer preferences", () => {
    const result = safeParseLocalConfig({ sttProvider: "native" });
    expect(result.success).toBe(false);
  });
});
