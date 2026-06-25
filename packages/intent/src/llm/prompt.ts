import type { GoalLoopObservation, IntentInput } from "@handsoff/contracts";

export interface ResolveIntentMessage {
  readonly role: "system" | "user";
  readonly content: string;
}

const SYSTEM_PROMPT =
  "You are HandsOff's autonomous computer-use agent. You pursue the user's GOAL by " +
  "choosing the NEXT action to take, given a LIVE snapshot of the screen, and you keep " +
  "going across turns until the goal is satisfied. You are the natural-language command " +
  "parser AND the step-by-step planner.\n" +
  "Each turn you receive: the goal, the latest perception snapshot (the focused window " +
  "and its accessibility elements, each with an `index`), the result of your previous " +
  "action (so you can recover from a failure by trying something else), and the ranked " +
  "candidate surfaces. Use only this supplied state — never invent windows, elements, or " +
  "indices.\n" +
  "Emit ONE next action as the action plan when more work is needed. Targeting actions " +
  "(click_element, type_text, set_value, inspect_window_state) MUST reference an element " +
  "by an `elementIndex` taken from the LATEST snapshot — never a guessed index. You may " +
  'launch a named macOS app before acting on it; a pure app-launch (e.g. "open Safari") ' +
  "is a single launch_app step with referent null — do not require a candidate surface and " +
  "never block it because a different app is active.\n" +
  "Combine actions across turns: to reveal hidden content, click to open a menu/list, then " +
  "act on what appears. When your previous action FAILED, do not repeat it — choose a " +
  "different action toward the goal.\n" +
  "Set status `satisfied` (with a summary) when the goal is already met. Set " +
  "`clarification_required` or `blocked` only when the target is genuinely ambiguous, " +
  "impossible, or unsafe. Never produce destructive actions.\n" +
  "For named app launch targets, use surface id app:<lowercase app name> with pid/windowId " +
  "null and unknown availability/access. For this/current app/window/document with no " +
  "candidate surfaces, use surface id active-window, title Active window, app Current app, " +
  "pid/windowId null, availability available, accessStatus accessible.";

// How many recent observations of loop memory to send. Enough for the model to
// see its last action's result and not repeat itself, bounded so a long goal's
// prompt stays small.
const RECENT_OBSERVATION_LIMIT = 3;

type SnapshotElement = {
  index: number | null;
  role: string | null;
  label: string | null;
  value: string | null;
};

// The focused window + its accessibility elements from a single observation —
// the live snapshot the model must cite element indices from.
function snapshotFor(observation: GoalLoopObservation | undefined): {
  focusedWindow: unknown;
  elements: readonly SnapshotElement[];
} | null {
  if (!observation) return null;
  const surface = observation.state?.surface ?? observation.windows[0];
  if (!surface) return null;
  const elements: readonly SnapshotElement[] = (observation.state?.elements ?? []).map(
    (element) => ({
      index: element.index ?? null,
      role: element.role ?? null,
      label: element.label ?? null,
      value: element.value ?? null,
    }),
  );
  return {
    focusedWindow: {
      id: surface.id,
      title: surface.title,
      app: surface.app,
      pid: surface.pid ?? null,
      windowId: surface.windowId ?? null,
      availability: surface.availability,
      accessStatus: surface.accessStatus,
    },
    elements,
  };
}

// The recent action results — the loop memory the model needs to recover from a
// failure instead of repeating it or losing track of progress.
function recentResults(
  observations: readonly GoalLoopObservation[],
): readonly { tick: number; status: string; detail: string }[] {
  return observations
    .slice(-RECENT_OBSERVATION_LIMIT)
    .filter(
      (
        observation,
      ): observation is GoalLoopObservation & {
        previousAction: NonNullable<GoalLoopObservation["previousAction"]>;
      } => observation.previousAction !== undefined,
    )
    .map((observation) => {
      const result = observation.previousAction.result;
      const detail =
        result.status === "succeeded"
          ? result.summary
          : result.status === "blocked"
            ? result.reason
            : result.error;
      return { tick: observation.tick, status: result.status, detail };
    });
}

export function buildResolveIntentMessages(input: IntentInput): ResolveIntentMessage[] {
  const observations = input.goalSession?.observations ?? [];
  const snapshot = snapshotFor(observations.at(-1));
  return [
    { role: "system", content: SYSTEM_PROMPT },
    {
      role: "user",
      content: JSON.stringify({
        goal: input.goalSession?.goal ?? input.speech.finalTranscript.text,
        transcript: {
          text: input.speech.finalTranscript.text,
          confidence: input.speech.finalTranscript.confidence,
        },
        // The live perception snapshot the model cites element indices from.
        // Null on the very first turn before the first observation lands.
        latestSnapshot: snapshot,
        // Loop memory: the recent action results so the model can recover.
        recentResults: recentResults(observations),
        candidateSurfaces: input.surfaceCandidates.map((surface, index) => ({
          rank: index + 1,
          id: surface.id,
          title: surface.title,
          app: surface.app,
          pid: surface.pid ?? null,
          windowId: surface.windowId ?? null,
          availability: surface.availability,
          accessStatus: surface.accessStatus,
        })),
      }),
    },
  ];
}
