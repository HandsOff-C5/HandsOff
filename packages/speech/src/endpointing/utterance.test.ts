import type { FinalTranscript, PartialTranscript, TranscriptWord } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import {
  EMPTY_UTTERANCE,
  endpointUtterance,
  foldUtterance,
  type UtteranceState,
} from "./utterance";

function word(text: string, startMs: number): TranscriptWord {
  return { text, startMs, endMs: startMs + 200, confidence: 0.9 };
}

function partial(text: string, words?: ReadonlyArray<TranscriptWord>): PartialTranscript {
  return {
    kind: "partial",
    text,
    confidence: 0,
    latencyMs: 0,
    receivedAt: 0,
    ...(words ? { words } : {}),
  };
}

function final(
  text: string,
  confidence = 1,
  latencyMs = 0,
  words?: ReadonlyArray<TranscriptWord>,
): FinalTranscript {
  return { kind: "final", text, confidence, latencyMs, receivedAt: 0, ...(words ? { words } : {}) };
}

function accumulate(...events: ReadonlyArray<PartialTranscript | FinalTranscript>): UtteranceState {
  return events.reduce(foldUtterance, EMPTY_UTTERANCE);
}

describe("foldUtterance", () => {
  it("keeps the latest partial as the unfinalized tail", () => {
    const state = accumulate(partial("hel"), partial("hello wor"));
    expect(state).toEqual({ finals: [], partial: "hello wor" });
  });

  it("appends finals in order and clears the partial they supersede", () => {
    const state = accumulate(partial("ope"), final("open the issue"));
    expect(state.finals.map((f) => f.text)).toEqual(["open the issue"]);
    expect(state.partial).toBe("");
  });

  it("does not mutate the prior state", () => {
    const before = accumulate(final("first"));
    const after = foldUtterance(before, final("second"));
    expect(before.finals.map((f) => f.text)).toEqual(["first"]);
    expect(after.finals.map((f) => f.text)).toEqual(["first", "second"]);
  });

  it("checkpoints pre-pause partial when provider resets to a new utterance", () => {
    const state = accumulate(
      partial("open slack in the comet browser"),
      partial("and send yes to opencode"),
    );
    expect(state.finals).toHaveLength(1);
    expect(state.finals[0]?.text).toBe("open slack in the comet browser");
    expect(state.partial).toBe("and send yes to opencode");
  });

  it("does not checkpoint when new partial extends the current", () => {
    const state = accumulate(partial("open"), partial("open slack in the browser"));
    expect(state.finals).toHaveLength(0);
    expect(state.partial).toBe("open slack in the browser");
  });

  it("does not checkpoint when new partial is a shorter revision", () => {
    const state = accumulate(partial("open slack in the browser"), partial("open Slack in the"));
    expect(state.finals).toHaveLength(0);
  });
});

describe("endpointUtterance", () => {
  it("joins multiple finals into one stable utterance", () => {
    const state = accumulate(
      final("open the issue", 0.9, 120),
      final("and brief the agent", 0.8, 200),
    );
    const result = endpointUtterance(state, { receivedAt: 5, includeTrailingPartial: true });
    expect(result).toEqual({
      kind: "final",
      text: "open the issue and brief the agent",
      // Weakest segment's confidence, slowest segment's latency.
      confidence: 0.8,
      latencyMs: 200,
      receivedAt: 5,
    });
  });

  it("includes the trailing partial on manual release", () => {
    const state = accumulate(final("open the"), partial("github issue"));
    const result = endpointUtterance(state, { receivedAt: 1, includeTrailingPartial: true });
    expect(result?.text).toBe("open the github issue");
  });

  it("omits the trailing partial when the provider already endpointed", () => {
    const state = accumulate(final("open the issue"), partial("and m"));
    const result = endpointUtterance(state, { receivedAt: 1, includeTrailingPartial: false });
    expect(result?.text).toBe("open the issue");
  });

  it("emits a partial-only utterance with zero confidence", () => {
    const state = accumulate(partial("just a partial"));
    const result = endpointUtterance(state, { receivedAt: 2, includeTrailingPartial: true });
    expect(result).toEqual({
      kind: "final",
      text: "just a partial",
      confidence: 0,
      latencyMs: 0,
      receivedAt: 2,
    });
  });

  it("collapses surrounding and interior whitespace", () => {
    const state = accumulate(final("  open   the  "), partial("  issue  "));
    const result = endpointUtterance(state, { receivedAt: 0, includeTrailingPartial: true });
    expect(result?.text).toBe("open the issue");
  });

  it("joins speech segments across a provider-reset pause with no mid-pause final", () => {
    const state = accumulate(
      partial("open slack in the comet browser"),
      partial("and send yes to opencode"),
    );
    const result = endpointUtterance(state, { receivedAt: 1, includeTrailingPartial: true });
    expect(result?.text).toBe("open slack in the comet browser and send yes to opencode");
  });

  it("returns null when nothing intelligible was captured", () => {
    expect(
      endpointUtterance(EMPTY_UTTERANCE, { receivedAt: 0, includeTrailingPartial: true }),
    ).toBeNull();
    const blank = accumulate(partial("   "));
    expect(endpointUtterance(blank, { receivedAt: 0, includeTrailingPartial: true })).toBeNull();
  });
});

describe("endpointUtterance — word timeline (U4)", () => {
  it("carries the folded word timeline from the contributing finals", () => {
    const state = accumulate(
      final("type laura in this", 0.9, 0, [word("type", 1000), word("laura", 1200)]),
      final("and hello in that", 0.9, 0, [word("and", 5000), word("hello", 5200)]),
    );
    const result = endpointUtterance(state, { receivedAt: 9, includeTrailingPartial: true });
    expect(result?.words?.map((w) => w.text)).toEqual(["type", "laura", "and", "hello"]);
    expect(result?.words?.map((w) => w.startMs)).toEqual([1000, 1200, 5000, 5200]);
  });

  it("folds the trailing partial's words on a manual release", () => {
    const state = accumulate(
      final("open the", 0.9, 0, [word("open", 1000), word("the", 1200)]),
      partial("github issue", [word("github", 1400), word("issue", 1600)]),
    );
    const result = endpointUtterance(state, { receivedAt: 1, includeTrailingPartial: true });
    expect(result?.words?.map((w) => w.text)).toEqual(["open", "the", "github", "issue"]);
  });

  it("drops the trailing partial's words when not included", () => {
    const state = accumulate(
      final("open the", 0.9, 0, [word("open", 1000)]),
      partial("github", [word("github", 1400)]),
    );
    const result = endpointUtterance(state, { receivedAt: 1, includeTrailingPartial: false });
    expect(result?.words?.map((w) => w.text)).toEqual(["open"]);
  });

  it("de-duplicates words re-reported at the same start across revisions", () => {
    // The same word folded twice (e.g. a partial then its final) appears once.
    const state = accumulate(
      partial("type", [word("type", 1000)]),
      final("type laura", 0.9, 0, [word("type", 1000), word("laura", 1200)]),
    );
    const result = endpointUtterance(state, { receivedAt: 1, includeTrailingPartial: true });
    expect(result?.words?.map((w) => w.startMs)).toEqual([1000, 1200]);
  });

  it("emits an ascending timeline even if segments arrive out of order", () => {
    const state = accumulate(
      final("later", 0.9, 0, [word("later", 5000)]),
      final("earlier", 0.9, 0, [word("earlier", 1000)]),
    );
    const result = endpointUtterance(state, { receivedAt: 1, includeTrailingPartial: true });
    expect(result?.words?.map((w) => w.startMs)).toEqual([1000, 5000]);
  });

  it("omits words entirely when no segment exposed word timing (on-device path)", () => {
    const state = accumulate(final("open the issue"), partial("and more"));
    const result = endpointUtterance(state, { receivedAt: 1, includeTrailingPartial: true });
    expect(result?.text).toBe("open the issue and more");
    expect(result?.words).toBeUndefined();
  });

  it("preserves the pre-pause partial's words across a provider reset", () => {
    const state = accumulate(
      partial("open slack", [word("open", 1000), word("slack", 1200)]),
      partial("and send yes", [word("and", 5000), word("send", 5200)]),
    );
    const result = endpointUtterance(state, { receivedAt: 1, includeTrailingPartial: true });
    // Checkpointed pre-pause words + the trailing partial's words, in order.
    expect(result?.words?.map((w) => w.text)).toEqual(["open", "slack", "and", "send"]);
  });
});
