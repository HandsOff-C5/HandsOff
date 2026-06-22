import type { TranscriptEvent } from "@handsoff/contracts";
import { FakeSttStream } from "@handsoff/testkit";
import { describe, expect, it } from "vitest";

import { EMPTY_UTTERANCE, endpointUtterance, foldUtterance } from "../endpointing";
import { recordTranscriptLatency } from "../latency";
import { CORE_LOOP_TRANSCRIPT_FIXTURES, CORE_LOOP_COMMAND_TYPES } from "./transcript-fixtures";

async function replay(events: readonly TranscriptEvent[]): Promise<readonly TranscriptEvent[]> {
  let now = 0;
  const stream = new FakeSttStream({ clock: () => now });
  const received: TranscriptEvent[] = [];

  await stream.start((event) => {
    if (event.kind !== "error") received.push(event);
  });

  for (const event of events) {
    now = event.receivedAt;
    if (event.kind === "partial") {
      stream.emitPartial(event.text, event.confidence, event.latencyMs);
    } else {
      stream.emitFinal(event.text, event.confidence, event.latencyMs);
    }
  }

  await stream.stop();
  return received;
}

function lastFinal(events: readonly TranscriptEvent[]): TranscriptEvent {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index];
    if (event?.kind === "final") return event;
  }
  throw new Error("fixture has no final transcript");
}

describe("core-loop transcript fixtures", () => {
  it("cover each supported voice command type once", () => {
    expect(CORE_LOOP_TRANSCRIPT_FIXTURES.map((fixture) => fixture.command)).toEqual(
      CORE_LOOP_COMMAND_TYPES,
    );
  });

  it.each(CORE_LOOP_TRANSCRIPT_FIXTURES)(
    "replays stored $command transcript output and records latency",
    async (fixture) => {
      const events = await replay(fixture.events);
      const final = lastFinal(fixture.events);

      const utterance = endpointUtterance(events.reduce(foldUtterance, EMPTY_UTTERANCE), {
        receivedAt: final.receivedAt,
        includeTrailingPartial: true,
      });

      expect(events).toEqual(fixture.events);
      expect(utterance).toEqual(fixture.expectedFinal);
      expect(recordTranscriptLatency(fixture.captureStartedAt, events)).toEqual(
        fixture.expectedLatency,
      );
    },
  );
});
