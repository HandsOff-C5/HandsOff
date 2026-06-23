// Narrow an unknown to a plain object before keyed access. Shared by the
// provider message parsers (hosted + on-device), which both validate raw
// JSON payloads field by field.
export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
