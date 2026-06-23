import { z } from "zod";

// STUB — red phase. The failing test in computer-use.test.ts demands the real
// computer_20251124 action schema; this placeholder rejects everything so the
// suite is red until the schema is implemented (green).
export const COMPUTER_ACTION_KINDS = [] as const;

export const computerActionSchema = z.never();
export type ComputerAction = z.infer<typeof computerActionSchema>;

export function safeParseComputerAction(
  input: unknown,
): z.SafeParseReturnType<unknown, ComputerAction> {
  return computerActionSchema.safeParse(input);
}
