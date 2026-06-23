import { describe, expect, it } from "vitest";

import { createSupervisionSessionStore } from "./session-store";

describe("supervision session store", () => {
  it("starts, runs, and finishes sessions with generated ids", () => {
    const store = createSupervisionSessionStore();

    const queued = store.start("2026-06-22T12:00:00.000Z");
    const running = store.run(queued.id, "2026-06-22T12:00:01.000Z");
    const finished = store.finish(queued.id, "succeeded", "2026-06-22T12:00:02.000Z");
    const next = store.start("2026-06-22T12:00:03.000Z");

    expect(queued).toMatchObject({ id: "session-1", status: "queued" });
    expect(running).toMatchObject({ id: "session-1", status: "running" });
    expect(finished).toMatchObject({
      id: "session-1",
      status: "succeeded",
      finishedAt: "2026-06-22T12:00:02.000Z",
    });
    expect(next).toMatchObject({ id: "session-2", status: "queued" });
    expect(store.list().map((session) => session.id)).toEqual(["session-1", "session-2"]);
  });
});
