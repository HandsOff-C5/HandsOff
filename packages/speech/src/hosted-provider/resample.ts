// Pure audio resampling for the AssemblyAI v3 streaming provider (#31).
//
// AssemblyAI v3 expects 16 kHz mono signed-16-bit little-endian PCM. The
// webview's AudioContext typically runs at 44.1 or 48 kHz and hands us Float32
// samples in [-1, 1]. This module converts a Float32 frame at an arbitrary
// input rate into an Int16Array at 16 kHz. No Web Audio APIs here — just the
// math — so it is fully testable in node/jsdom.

export const TARGET_SAMPLE_RATE = 16000;

// Clamp a Float32 sample in [-1, 1] and scale to the Int16 range. Out-of-range
// inputs are clamped rather than wrapped, so a hot mic never produces a noise
// spike from integer overflow.
function floatToInt16(sample: number): number {
  const clamped = Math.min(1, Math.max(-1, sample));
  // Negative full-scale maps to -32768, positive to 32767.
  return clamped < 0 ? Math.round(clamped * 32768) : Math.round(clamped * 32767);
}

// Downsample (or pass through) a Float32 frame to 16 kHz Int16 PCM using linear
// interpolation. When `inputRate === targetRate` the frame is converted 1:1.
export function resampleToPcm16(
  input: Float32Array,
  inputRate: number,
  targetRate: number = TARGET_SAMPLE_RATE,
): Int16Array {
  if (input.length === 0) return new Int16Array(0);
  if (inputRate <= 0) throw new Error(`resampleToPcm16: invalid inputRate ${inputRate}`);

  if (inputRate === targetRate) {
    const out = new Int16Array(input.length);
    for (let i = 0; i < input.length; i += 1) {
      out[i] = floatToInt16(input[i] ?? 0);
    }
    return out;
  }

  const ratio = inputRate / targetRate;
  const outLength = Math.floor(input.length / ratio);
  const out = new Int16Array(outLength);
  for (let i = 0; i < outLength; i += 1) {
    const srcPos = i * ratio;
    const left = Math.floor(srcPos);
    const right = Math.min(left + 1, input.length - 1);
    const frac = srcPos - left;
    const sample = (input[left] ?? 0) * (1 - frac) + (input[right] ?? 0) * frac;
    out[i] = floatToInt16(sample);
  }
  return out;
}
