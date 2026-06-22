import { describe, expect, it } from "vitest";

import { fakeActionTarget, fakeCuaActionResult, fakeCuaWindowState } from "./index";

describe("fake CUA fixtures", () => {
  it("builds target, state, and result fixtures from the shared contracts", () => {
    expect(fakeActionTarget().surface.id).toBe("surface-1");
    expect(fakeCuaWindowState().elements[0]?.label).toBe("Save");
    expect(fakeCuaActionResult()).toMatchObject({
      status: "succeeded",
      state: { surface: { id: "surface-1" } },
    });
  });
});
