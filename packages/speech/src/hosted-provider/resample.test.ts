import { describe, expect, it } from "vitest";

import { resampleToPcm16, TARGET_SAMPLE_RATE } from "./resample";

describe("resampleToPcm16", () => {
  it("downsamples 48 kHz input to roughly one third the sample count", () => {
    const input = new Float32Array(48000).fill(0);
    const out = resampleToPcm16(input, 48000);
    expect(out.length).toBe(16000);
  });

  it("passes 16 kHz input through unchanged in length", () => {
    const input = new Float32Array(800).fill(0);
    const out = resampleToPcm16(input, TARGET_SAMPLE_RATE);
    expect(out.length).toBe(800);
  });

  it("maps full-scale floats to the Int16 extremes", () => {
    const out = resampleToPcm16(new Float32Array([1, -1, 0]), TARGET_SAMPLE_RATE);
    expect(out[0]).toBe(32767);
    expect(out[1]).toBe(-32768);
    expect(out[2]).toBe(0);
  });

  it("clamps out-of-range floats instead of overflowing", () => {
    const out = resampleToPcm16(new Float32Array([1.5, -2]), TARGET_SAMPLE_RATE);
    expect(out[0]).toBe(32767);
    expect(out[1]).toBe(-32768);
  });

  it("returns an empty array for empty input", () => {
    expect(resampleToPcm16(new Float32Array(0), 48000).length).toBe(0);
  });

  it("interpolates linearly between samples when downsampling 2:1", () => {
    // Input at 32 kHz -> 16 kHz, ratio 2: output[i] samples input[2i].
    const input = new Float32Array([0, 0.5, 1, 0.5]);
    const out = resampleToPcm16(input, 32000);
    expect(out.length).toBe(2);
    expect(out[0]).toBe(0);
    expect(out[1]).toBe(floatExpect(1));
  });

  it("throws on a non-positive input rate", () => {
    expect(() => resampleToPcm16(new Float32Array([0]), 0)).toThrow();
  });
});

function floatExpect(sample: number): number {
  return sample < 0 ? Math.round(sample * 32768) : Math.round(sample * 32767);
}
