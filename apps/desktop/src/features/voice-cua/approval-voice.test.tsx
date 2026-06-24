import { describe, expect, it } from "vitest";

import { parseApprovalUtterance } from "./approval-voice";

describe("parseApprovalUtterance", () => {
  it("reads an approval from affirmative words", () => {
    expect(parseApprovalUtterance("approve")).toBe("allow");
    expect(parseApprovalUtterance("Approve.")).toBe("allow");
    expect(parseApprovalUtterance("yes go ahead")).toBe("allow");
    expect(parseApprovalUtterance("do it")).toBe("allow");
    expect(parseApprovalUtterance("confirm")).toBe("allow");
  });

  it("reads a denial from negative words", () => {
    expect(parseApprovalUtterance("deny")).toBe("deny");
    expect(parseApprovalUtterance("no, stop")).toBe("deny");
    expect(parseApprovalUtterance("cancel that")).toBe("deny");
    expect(parseApprovalUtterance("don't")).toBe("deny");
  });

  it("lets a denial win when both appear (safety-first)", () => {
    expect(parseApprovalUtterance("no, don't approve")).toBe("deny");
  });

  it("returns null when the utterance is neither", () => {
    expect(parseApprovalUtterance("press seven plus five")).toBeNull();
    expect(parseApprovalUtterance("")).toBeNull();
    expect(parseApprovalUtterance("   ")).toBeNull();
  });
});
