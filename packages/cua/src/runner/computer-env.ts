import type { ComputerAction } from "@handsoff/contracts";

import type { ActionOutcome, ComputerEnv } from "./computer-use-loop";

// STUB — red phase. The failing test demands the real mapping + env.
export type DriverCall =
  | { kind: "wait"; ms: number }
  | { kind: "invoke"; command: string; args: Record<string, unknown>; expectsScreenshot: boolean };

export function computerActionToDriverCall(action: ComputerAction): DriverCall {
  void action;
  return { kind: "wait", ms: 0 };
}

export type CuaInvoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;

export function createTauriComputerEnv(deps: {
  invoke: CuaInvoke;
  wait?: (ms: number) => Promise<void>;
}): ComputerEnv {
  void deps;
  return {
    async execute(): Promise<ActionOutcome> {
      return { status: "error", error: "not implemented" };
    },
  };
}
