import type { PointingCandidate, SurfaceSnapshot, TranscriptWord } from "@handsoff/contracts";
import { describe, expect, it } from "vitest";

import type { AttentionWindow } from "../attention/candidates";
import {
  bindTemporalDeixis,
  isDeicticWord,
  type HandTraceSample,
  type HeadTraceSample,
} from "./temporal-binder";

// Two surfaces sitting side by side on the virtual desktop: Notes on the left,
// Slack on the right. The binder must route the first deictic to one and the
// second to the other based on WHEN each word was spoken.
const notesSurface: SurfaceSnapshot = {
  id: "win-notes",
  title: "Notes",
  app: "Notes",
  availability: "available",
  accessStatus: "accessible",
};
const slackSurface: SurfaceSnapshot = {
  id: "win-slack",
  title: "Slack",
  app: "Slack",
  availability: "available",
  accessStatus: "accessible",
};

const windows: readonly AttentionWindow[] = [
  { surface: notesSurface, bounds: { x: 0, y: 0, width: 400, height: 400 } },
  { surface: slackSurface, bounds: { x: 1000, y: 0, width: 400, height: 400 } },
];

function word(text: string, startMs: number, endMs: number): TranscriptWord {
  return { text, startMs, endMs, confidence: 0.9 };
}

function handAt(
  tsMs: number,
  targetId: string,
  phase: HandTraceSample["phase"] = "locked",
  confidence = 0.85,
): HandTraceSample {
  const candidate: PointingCandidate = { targetId, confidence, calibrationQuality: "good" };
  // The point is incidental for hand samples (the candidate already resolves the
  // surface); put it inside the target window for realism.
  const x = targetId === "win-notes" ? 200 : 1200;
  return { x, y: 200, candidate, phase, tsMs };
}

function headAt(tsMs: number, x: number, confidence = 0.8): HeadTraceSample {
  return { x, y: 200, confidence, tsMs };
}

describe("isDeicticWord", () => {
  it("matches the deictic vocabulary case- and punctuation-insensitively", () => {
    expect(isDeicticWord("this")).toBe(true);
    expect(isDeicticWord("This,")).toBe(true);
    expect(isDeicticWord("THAT")).toBe(true);
    expect(isDeicticWord("these")).toBe(true);
    expect(isDeicticWord("those")).toBe(true);
    expect(isDeicticWord("here")).toBe(true);
    expect(isDeicticWord("there.")).toBe(true);
  });

  it("rejects non-deictic words", () => {
    expect(isDeicticWord("type")).toBe(false);
    expect(isDeicticWord("Laura")).toBe(false);
    expect(isDeicticWord("the")).toBe(false);
  });
});

describe("bindTemporalDeixis — multi-target (the Notes/Slack case)", () => {
  it("binds two deictic words at different times to two DIFFERENT surfaces", () => {
    // "type Laura in THIS [@1000] and hello in THAT [@5000]"
    const words = [
      word("type", 100, 300),
      word("Laura", 300, 600),
      word("in", 600, 800),
      word("this", 1000, 1300),
      word("and", 3000, 3200),
      word("hello", 3200, 3600),
      word("in", 3600, 3800),
      word("that", 5000, 5300),
    ];
    const handTrace = [handAt(1100, "win-notes"), handAt(5100, "win-slack")];

    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace, windows });

    expect(bindings).toHaveLength(2);
    expect(bindings[0]?.word).toBe("this");
    expect(bindings[0]?.evidence?.surface?.id).toBe("win-notes");
    expect(bindings[1]?.word).toBe("that");
    expect(bindings[1]?.evidence?.surface?.id).toBe("win-slack");
    // The two referents are distinct surfaces.
    expect(bindings[0]?.evidence?.surface?.id).not.toBe(bindings[1]?.evidence?.surface?.id);
  });

  it("stamps the strategy with the bound word and the sample timestamp", () => {
    const words = [word("this", 1000, 1300)];
    const handTrace = [handAt(1100, "win-notes")];
    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace, windows });
    expect(bindings[0]?.evidence?.source).toBe("fusion");
    expect(bindings[0]?.evidence?.strategy).toBe("temporal-bind:this@1100");
  });
});

describe("bindTemporalDeixis — gesture-precedes-speech tolerance", () => {
  it("binds a gesture 800ms BEFORE the word (within tolerance)", () => {
    const words = [word("this", 2000, 2300)];
    // The only hand sample fired at 1200 — 800ms before the word starts.
    const handTrace = [handAt(1200, "win-notes")];
    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace, windows });
    expect(bindings[0]?.evidence?.surface?.id).toBe("win-notes");
  });

  it("does NOT bind a gesture far outside the tolerance window", () => {
    const words = [word("this", 5000, 5300)];
    // Gesture at 1000 — 4s before the word, well beyond the 1.5s default tolerance.
    const handTrace = [handAt(1000, "win-notes")];
    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace, windows });
    expect(bindings[0]?.evidence).toBeNull();
  });

  it("does NOT bind a gesture that lands AFTER the word ends", () => {
    const words = [word("this", 1000, 1300)];
    // Gesture at 2000 — after the word ended; speech-precedes-gesture is not allowed.
    const handTrace = [handAt(2000, "win-notes")];
    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace, windows });
    expect(bindings[0]?.evidence).toBeNull();
  });

  it("honors a custom tolerance", () => {
    const words = [word("this", 2000, 2300)];
    const handTrace = [handAt(1200, "win-notes")]; // 800ms before
    const tight = bindTemporalDeixis({
      words,
      headTrace: [],
      handTrace,
      windows,
      toleranceMs: 500,
    });
    expect(tight[0]?.evidence).toBeNull();
  });
});

describe("bindTemporalDeixis — unbound, not mis-bound", () => {
  it("leaves a deictic word with NO nearby sample unbound", () => {
    const words = [word("type", 100, 300), word("this", 1000, 1300)];
    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace: [], windows });
    expect(bindings).toHaveLength(1);
    expect(bindings[0]?.word).toBe("this");
    expect(bindings[0]?.evidence).toBeNull();
  });

  it("binds the word that has a sample and leaves the one without it unbound", () => {
    const words = [word("this", 1000, 1300), word("that", 5000, 5300)];
    // Only the first word has a bracketing hand sample.
    const handTrace = [handAt(1100, "win-notes")];
    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace, windows });
    expect(bindings[0]?.evidence?.surface?.id).toBe("win-notes");
    expect(bindings[1]?.evidence).toBeNull();
  });

  it("binds to the window UNDER the hand point when the targetId doesn't match a window", () => {
    const words = [word("this", 1000, 1300)];
    // Bug 5: the gesture lane resolved a DISPLAY id ("display-1") that isn't a
    // pointable window, but the hand point sits inside Slack → bind to that real
    // window via the point→window fallback instead of dropping the hand signal.
    const handTrace: HandTraceSample[] = [
      {
        x: 1200,
        y: 200,
        candidate: { targetId: "display-1", confidence: 0.85, calibrationQuality: "good" },
        phase: "locked",
        tsMs: 1100,
      },
    ];
    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace, windows });
    expect(bindings[0]?.evidence?.surface?.id).toBe("win-slack");
    // Confidence is the hand's own (the primary modality), not a head-rank score.
    expect(bindings[0]?.evidence?.confidence).toBe(0.85);
  });

  it("leaves a word unbound when the targetId is unknown AND the point is outside every window", () => {
    const words = [word("this", 1000, 1300)];
    // Unknown targetId and the point is far from any window (beyond the ranker's
    // neighborhood) → no window to fall back to → unbound, not mis-bound.
    const handTrace: HandTraceSample[] = [
      {
        x: 5000,
        y: 5000,
        candidate: { targetId: "display-1", confidence: 0.85, calibrationQuality: "good" },
        phase: "locked",
        tsMs: 1100,
      },
    ];
    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace, windows });
    expect(bindings[0]?.evidence).toBeNull();
  });
});

describe("bindTemporalDeixis — single deictic / single target (back-compat)", () => {
  it("produces exactly one referent", () => {
    const words = [word("click", 100, 400), word("this", 1000, 1300)];
    const handTrace = [handAt(1100, "win-notes")];
    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace, windows });
    expect(bindings).toHaveLength(1);
    expect(bindings[0]?.evidence?.surface?.id).toBe("win-notes");
    expect(bindings[0]?.evidence?.confidence).toBe(0.85);
  });
});

describe("bindTemporalDeixis — modality precedence", () => {
  it("prefers a locked hand referent over a head point at the same instant", () => {
    const words = [word("this", 1000, 1300)];
    // Hand locked on Notes; head aimed at Slack — hand wins.
    const handTrace = [handAt(1100, "win-notes", "locked")];
    const headTrace = [headAt(1100, 1200)]; // x=1200 sits inside Slack's bounds
    const bindings = bindTemporalDeixis({ words, headTrace, handTrace, windows });
    expect(bindings[0]?.evidence?.surface?.id).toBe("win-notes");
  });

  it("prefers a locked hand sample over a non-locked one in the same window", () => {
    const words = [word("this", 1000, 1300)];
    const handTrace = [
      handAt(1050, "win-slack", "candidate", 0.95), // cursor, higher confidence, earlier
      handAt(1150, "win-notes", "locked", 0.6), // locked, lower confidence
    ];
    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace, windows });
    // Locked beats cursor even though the cursor sample has higher confidence.
    expect(bindings[0]?.evidence?.surface?.id).toBe("win-notes");
  });

  it("falls back to the head point when no hand sample brackets the word", () => {
    const words = [word("this", 1000, 1300)];
    // No hand sample; head aimed inside Notes (x=200).
    const headTrace = [headAt(1100, 200)];
    const bindings = bindTemporalDeixis({ words, headTrace, handTrace: [], windows });
    expect(bindings[0]?.evidence?.surface?.id).toBe("win-notes");
    // Head confidence comes from the ranker's score (point inside bounds → 1).
    expect(bindings[0]?.evidence?.confidence).toBe(1);
  });

  it("ignores a hand sample with no candidate and uses the head instead", () => {
    const words = [word("this", 1000, 1300)];
    const handTrace: HandTraceSample[] = [
      { x: 200, y: 200, candidate: null, phase: "idle", tsMs: 1100 },
    ];
    const headTrace = [headAt(1100, 1200)]; // inside Slack
    const bindings = bindTemporalDeixis({ words, headTrace, handTrace, windows });
    expect(bindings[0]?.evidence?.surface?.id).toBe("win-slack");
  });
});

describe("bindTemporalDeixis — point→window picks the frontmost overlapping window", () => {
  const back: SurfaceSnapshot = {
    id: "win-back",
    title: "Back",
    app: "Back",
    availability: "available",
    accessStatus: "accessible",
  };
  const front: SurfaceSnapshot = {
    id: "win-front",
    title: "Front",
    app: "Front",
    availability: "available",
    accessStatus: "accessible",
  };
  // Two windows over the SAME region; `front` is frontmost (higher zIndex).
  const overlapping: readonly AttentionWindow[] = [
    { surface: back, bounds: { x: 0, y: 0, width: 500, height: 500 }, zIndex: 1 },
    { surface: front, bounds: { x: 0, y: 0, width: 500, height: 500 }, zIndex: 9 },
  ];

  it("binds the hand point to the frontmost window when two windows overlap it (Bug 5/3 z-order)", () => {
    const words = [word("here", 1000, 1300)];
    // targetId doesn't match → resolves by point; both windows contain (250,250),
    // so the frontmost (front) must win.
    const handTrace: HandTraceSample[] = [
      {
        x: 250,
        y: 250,
        candidate: { targetId: "display-1", confidence: 0.85, calibrationQuality: "good" },
        phase: "locked",
        tsMs: 1100,
      },
    ];
    const bindings = bindTemporalDeixis({ words, headTrace: [], handTrace, windows: overlapping });
    expect(bindings[0]?.evidence?.surface?.id).toBe("win-front");
  });

  it("binds the head point to the frontmost overlapping window too", () => {
    const words = [word("here", 1000, 1300)];
    const headTrace = [headAt(1100, 250)]; // x=250,y=200 inside both windows
    const bindings = bindTemporalDeixis({ words, headTrace, handTrace: [], windows: overlapping });
    expect(bindings[0]?.evidence?.surface?.id).toBe("win-front");
  });
});
