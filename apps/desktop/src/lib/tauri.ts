// True only when running inside the Tauri shell (native backend reachable).
// In a plain browser / jsdom this is false, so callers fall back to a no-op
// or a default instead of invoking a command that would reject.
export function hasTauriBackend(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}
