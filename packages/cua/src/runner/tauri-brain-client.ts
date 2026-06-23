import type { CuaInvoke } from "../tauri-driver";
import type { ComputerUseClient } from "./anthropic-brain-adapter";

// The Tauri command the host exposes for one computer-use brain step. Mirrors
// `intent_resolve`: the webview forwards the request; the Rust side holds the
// Anthropic key (local .env for the demo, a worker later) and makes the call,
// so the key never reaches the webview.
export const CUA_BRAIN_COMMAND = "cua_brain_step";

export function createTauriComputerUseClient(
  invoke: CuaInvoke,
  command: string = CUA_BRAIN_COMMAND,
): ComputerUseClient {
  return {
    createMessage(request) {
      return invoke<unknown>(command, { request });
    },
  };
}
