import type { GateDecision } from "@handsoff/cua";

// Spoken approve/deny for the agent's pending mutating step, so the operator
// resolves the CUA gate hands-off ("approve" / "deny") instead of clicking.
// Deny-first: if a denial word appears at all, halt — a spoken "no"/"stop"
// must never be overridden by an "approve" elsewhere in the same utterance.

const ALLOW = [
  "approve",
  "approved",
  "yes",
  "yeah",
  "yep",
  "confirm",
  "confirmed",
  "allow",
  "accept",
  "okay",
  "ok",
  "proceed",
  "go ahead",
  "do it",
];

const DENY = [
  "deny",
  "denied",
  "no",
  "nope",
  "stop",
  "cancel",
  "reject",
  "rejected",
  "abort",
  "dont",
  "don't",
  "do not",
];

// Map a final transcript to an approval decision, or null when it's neither.
export function parseApprovalUtterance(text: string): GateDecision | null {
  const norm = text
    .toLowerCase()
    .replace(/[^a-z0-9'\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!norm) return null;
  const tokens = new Set(norm.split(" "));
  const hasPhrase = (phrases: string[]): boolean =>
    phrases.some((phrase) => (phrase.includes(" ") ? norm.includes(phrase) : tokens.has(phrase)));
  if (hasPhrase(DENY)) return "deny";
  if (hasPhrase(ALLOW)) return "allow";
  return null;
}
