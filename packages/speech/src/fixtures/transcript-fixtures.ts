import type { FinalTranscript, TranscriptEvent } from "@handsoff/contracts";

import type { TranscriptLatencyRecord } from "../latency";

export const CORE_LOOP_COMMAND_TYPES = [
  "select",
  "inspect",
  "delegate",
  "approve",
  "reject",
  "pause",
  "stop",
] as const;

export type CoreLoopCommandType = (typeof CORE_LOOP_COMMAND_TYPES)[number];

export interface TranscriptFixture {
  readonly command: CoreLoopCommandType;
  readonly captureStartedAt: number;
  readonly events: readonly TranscriptEvent[];
  readonly expectedFinal: FinalTranscript;
  readonly expectedLatency: TranscriptLatencyRecord;
}

export const CORE_LOOP_TRANSCRIPT_FIXTURES = [
  {
    command: "select",
    captureStartedAt: 1_800_000_000_000,
    events: [
      {
        kind: "partial",
        text: "select",
        confidence: 0.62,
        latencyMs: 35,
        receivedAt: 1_800_000_000_090,
      },
      {
        kind: "partial",
        text: "select the latest",
        confidence: 0.68,
        latencyMs: 45,
        receivedAt: 1_800_000_000_170,
      },
      {
        kind: "final",
        text: "select the latest browser window",
        confidence: 0.94,
        latencyMs: 82,
        receivedAt: 1_800_000_000_260,
      },
    ],
    expectedFinal: {
      kind: "final",
      text: "select the latest browser window",
      confidence: 0.94,
      latencyMs: 82,
      receivedAt: 1_800_000_000_260,
    },
    expectedLatency: {
      kind: "transcript-latency",
      captureStartedAt: 1_800_000_000_000,
      finalReceivedAt: 1_800_000_000_260,
      captureToFinalMs: 260,
      finalTranscriptLatencyMs: 82,
      transcriptText: "select the latest browser window",
      eventCount: 3,
    },
  },
  {
    command: "inspect",
    captureStartedAt: 1_800_000_001_000,
    events: [
      {
        kind: "partial",
        text: "inspect",
        confidence: 0.61,
        latencyMs: 32,
        receivedAt: 1_800_000_001_080,
      },
      {
        kind: "partial",
        text: "inspect this error",
        confidence: 0.69,
        latencyMs: 48,
        receivedAt: 1_800_000_001_185,
      },
      {
        kind: "final",
        text: "inspect this error state",
        confidence: 0.92,
        latencyMs: 90,
        receivedAt: 1_800_000_001_315,
      },
    ],
    expectedFinal: {
      kind: "final",
      text: "inspect this error state",
      confidence: 0.92,
      latencyMs: 90,
      receivedAt: 1_800_000_001_315,
    },
    expectedLatency: {
      kind: "transcript-latency",
      captureStartedAt: 1_800_000_001_000,
      finalReceivedAt: 1_800_000_001_315,
      captureToFinalMs: 315,
      finalTranscriptLatencyMs: 90,
      transcriptText: "inspect this error state",
      eventCount: 3,
    },
  },
  {
    command: "delegate",
    captureStartedAt: 1_800_000_002_000,
    events: [
      {
        kind: "partial",
        text: "delegate",
        confidence: 0.58,
        latencyMs: 38,
        receivedAt: 1_800_000_002_095,
      },
      {
        kind: "partial",
        text: "delegate this cleanup",
        confidence: 0.72,
        latencyMs: 55,
        receivedAt: 1_800_000_002_210,
      },
      {
        kind: "final",
        text: "delegate this cleanup to the agent",
        confidence: 0.91,
        latencyMs: 118,
        receivedAt: 1_800_000_002_390,
      },
    ],
    expectedFinal: {
      kind: "final",
      text: "delegate this cleanup to the agent",
      confidence: 0.91,
      latencyMs: 118,
      receivedAt: 1_800_000_002_390,
    },
    expectedLatency: {
      kind: "transcript-latency",
      captureStartedAt: 1_800_000_002_000,
      finalReceivedAt: 1_800_000_002_390,
      captureToFinalMs: 390,
      finalTranscriptLatencyMs: 118,
      transcriptText: "delegate this cleanup to the agent",
      eventCount: 3,
    },
  },
  {
    command: "approve",
    captureStartedAt: 1_800_000_003_000,
    events: [
      {
        kind: "partial",
        text: "approve",
        confidence: 0.75,
        latencyMs: 28,
        receivedAt: 1_800_000_003_070,
      },
      {
        kind: "final",
        text: "approve the plan",
        confidence: 0.98,
        latencyMs: 64,
        receivedAt: 1_800_000_003_205,
      },
    ],
    expectedFinal: {
      kind: "final",
      text: "approve the plan",
      confidence: 0.98,
      latencyMs: 64,
      receivedAt: 1_800_000_003_205,
    },
    expectedLatency: {
      kind: "transcript-latency",
      captureStartedAt: 1_800_000_003_000,
      finalReceivedAt: 1_800_000_003_205,
      captureToFinalMs: 205,
      finalTranscriptLatencyMs: 64,
      transcriptText: "approve the plan",
      eventCount: 2,
    },
  },
  {
    command: "reject",
    captureStartedAt: 1_800_000_004_000,
    events: [
      {
        kind: "partial",
        text: "reject",
        confidence: 0.7,
        latencyMs: 34,
        receivedAt: 1_800_000_004_085,
      },
      {
        kind: "final",
        text: "reject that action",
        confidence: 0.96,
        latencyMs: 73,
        receivedAt: 1_800_000_004_235,
      },
    ],
    expectedFinal: {
      kind: "final",
      text: "reject that action",
      confidence: 0.96,
      latencyMs: 73,
      receivedAt: 1_800_000_004_235,
    },
    expectedLatency: {
      kind: "transcript-latency",
      captureStartedAt: 1_800_000_004_000,
      finalReceivedAt: 1_800_000_004_235,
      captureToFinalMs: 235,
      finalTranscriptLatencyMs: 73,
      transcriptText: "reject that action",
      eventCount: 2,
    },
  },
  {
    command: "pause",
    captureStartedAt: 1_800_000_005_000,
    events: [
      {
        kind: "partial",
        text: "pause",
        confidence: 0.77,
        latencyMs: 30,
        receivedAt: 1_800_000_005_075,
      },
      {
        kind: "final",
        text: "pause execution",
        confidence: 0.95,
        latencyMs: 67,
        receivedAt: 1_800_000_005_215,
      },
    ],
    expectedFinal: {
      kind: "final",
      text: "pause execution",
      confidence: 0.95,
      latencyMs: 67,
      receivedAt: 1_800_000_005_215,
    },
    expectedLatency: {
      kind: "transcript-latency",
      captureStartedAt: 1_800_000_005_000,
      finalReceivedAt: 1_800_000_005_215,
      captureToFinalMs: 215,
      finalTranscriptLatencyMs: 67,
      transcriptText: "pause execution",
      eventCount: 2,
    },
  },
  {
    command: "stop",
    captureStartedAt: 1_800_000_006_000,
    events: [
      {
        kind: "partial",
        text: "stop",
        confidence: 0.79,
        latencyMs: 29,
        receivedAt: 1_800_000_006_065,
      },
      {
        kind: "final",
        text: "stop the run",
        confidence: 0.97,
        latencyMs: 69,
        receivedAt: 1_800_000_006_225,
      },
    ],
    expectedFinal: {
      kind: "final",
      text: "stop the run",
      confidence: 0.97,
      latencyMs: 69,
      receivedAt: 1_800_000_006_225,
    },
    expectedLatency: {
      kind: "transcript-latency",
      captureStartedAt: 1_800_000_006_000,
      finalReceivedAt: 1_800_000_006_225,
      captureToFinalMs: 225,
      finalTranscriptLatencyMs: 69,
      transcriptText: "stop the run",
      eventCount: 2,
    },
  },
] satisfies readonly TranscriptFixture[];
