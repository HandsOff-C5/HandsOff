import { describe, expect, it } from "vitest";

describe("testkit smoke", () => {
  it("runs the vitest pipeline", () => {
    expect(1 + 1).toBe(2);
  });
});
