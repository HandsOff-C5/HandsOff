import type {
  DriverToolDefinition,
  GoalLoopObservation,
  IntentInput,
  PointingEvidence,
} from "@handsoff/contracts";

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

// The candidate surface list for the user payload. The legacy 6-kind prompt
// passes no evidence and stays WEIGHTLESS (its golden + "no raw camera data"
// contract depend on that exact shape); the autonomous-loop prompt passes the
// pointing evidence so each candidate also carries the pointing confidence + the
// modality that produced it (KD5) — a weightless list let the model guess and
// punt ("ambiguous target"), so this is the signal that closes that gap.
function candidateSurfacesFor(input: IntentInput, evidence?: readonly PointingEvidence[]) {
  return input.surfaceCandidates.map((surface, index) => ({
    rank: index + 1,
    id: surface.id,
    title: surface.title,
    app: surface.app,
    pid: surface.pid ?? null,
    windowId: surface.windowId ?? null,
    availability: surface.availability,
    accessStatus: surface.accessStatus,
    // Null when no pointing evidence references this surface; absent entirely on
    // the legacy prompt (no evidence passed).
    ...(evidence ? confidenceForSurface(surface.id, evidence) : {}),
  }));
}

// The strongest pointing evidence carrying this surface — its confidence and
// source ground the candidate so the model can act on deixis instead of guessing.
function confidenceForSurface(
  surfaceId: string,
  evidence: readonly PointingEvidence[],
): { confidence: number; source: PointingEvidence["source"] } | { confidence: null; source: null } {
  const best = evidence
    .filter((e) => e.surface?.id === surfaceId)
    .reduce<PointingEvidence | null>(
      (top, e) => (top === null || e.confidence > top.confidence ? e : top),
      null,
    );
  return best
    ? { confidence: best.confidence, source: best.source }
    : { confidence: null, source: null };
}

// The temporally-bound deictic referents (KD4/KD5): each `fusion` pointing-
// evidence entry the temporal binder emitted for a deictic word ("this"/"that"),
// carrying the surface it bound to and the confidence behind it. The binder
// stamps the bound word + sample time in `strategy` (`temporal-bind:<word>@<ts>`),
// surfaced here so the model knows WHICH deictic resolved to WHICH window — the
// signal that was previously assembled but withheld from the model.
function boundReferentsFor(input: IntentInput) {
  return input.pointingEvidence
    .filter((e) => e.source === "fusion" && e.surface !== undefined)
    .map((e) => ({
      word: deicticWordFromStrategy(e.strategy),
      surfaceId: e.surface?.id ?? null,
      app: e.surface?.app ?? null,
      title: e.surface?.title ?? null,
      confidence: e.confidence,
      strategy: e.strategy,
    }));
}

// Recover the deictic word the binder stamped into `temporal-bind:<word>@<ts>`,
// so the presented referent reads "this → Notes" rather than a bare surface id.
// Null for a fusion strategy that doesn't follow the temporal-bind shape.
function deicticWordFromStrategy(strategy: string): string | null {
  const match = /^temporal-bind:([^@]+)@/.exec(strategy);
  return match?.[1] ?? null;
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
        candidateSurfaces: candidateSurfacesFor(input),
      }),
    },
  ];
}

// The full-surface autonomous-loop prompt (U3b). Same live state as
// buildResolveIntentMessages — goal + perception snapshot (with element indices)
// + loop memory + candidates — but the model now chooses ONE call from the whole
// cua-driver tool surface (passed in as the catalog) and returns it in the
// next-tool-call schema, instead of a closed 6-kind ActionStep.
const NEXT_TOOL_CALL_SYSTEM_PROMPT =
  "You are HandsOff's autonomous computer-use agent. You pursue the user's GOAL by " +
  "calling ONE cua-driver tool at a time, observing the result, and continuing across turns " +
  "until the goal is done. You drive a real macOS desktop without stealing keyboard focus.\n" +
  "Each turn you receive: the goal, the latest perception snapshot (the focused window + its " +
  "accessibility elements, each with an `index`, plus its `pid`/`windowId`), the result of " +
  "your previous tool call (recover from a failure by trying something else — never repeat a " +
  "failed call), the ranked candidate surfaces, and the list of available tools with their " +
  "JSON-Schema parameters. Use ONLY this supplied state — never invent windows, elements, or " +
  "indices.\n" +
  "Return status `act` with `tool` (one of the listed tool names) and `args` (the tool's raw " +
  "flat arguments, matching its parameter schema — e.g. pid, window_id, element_index, " +
  "direction). Targeting calls (click, type_text, set_value, scroll, press_key, …) MUST cite " +
  "an `element_index` AND `window_id` from the LATEST snapshot, plus its `pid` — never a " +
  "guessed index. Combine actions across turns: to reveal hidden content, scroll or click a " +
  "menu open, then act on what appears.\n" +
  "Return status `done` with a `summary` when the goal is already satisfied. Return `clarify` " +
  "or `blocked` with a `reason` only when the target is genuinely ambiguous, impossible, or " +
  "unsafe. Always give a one-line `rationale` for an `act`. Prefer reversible/draft actions; " +
  "the supervisor approves anything that commits (sends/deletes/etc.).\n" +
  "`boundReferents` lists each deictic word the user spoke (this/that/here/…) already RESOLVED " +
  "to the surface they were pointing at WHILE saying it, with a confidence. Trust these over " +
  "your own guess: when the goal says 'type X in this and Y in that', map the first deictic to " +
  "its bound surface and the second to its own — do NOT collapse them to one target or ask for " +
  "clarification when a referent is bound. `candidateSurfaces` carries the same pointing " +
  "`confidence`/`source` per surface so you can pick the strongest when no deictic is bound.";

function toolMenu(tools: readonly DriverToolDefinition[]) {
  return tools.map((tool) => ({
    name: tool.name,
    description: tool.description,
    parameters: tool.inputSchema ?? null,
  }));
}

export function buildNextToolCallMessages(
  input: IntentInput,
  tools: readonly DriverToolDefinition[],
): ResolveIntentMessage[] {
  const observations = input.goalSession?.observations ?? [];
  const snapshot = snapshotFor(observations.at(-1));
  return [
    { role: "system", content: NEXT_TOOL_CALL_SYSTEM_PROMPT },
    {
      role: "user",
      content: JSON.stringify({
        goal: input.goalSession?.goal ?? input.speech.finalTranscript.text,
        transcript: {
          text: input.speech.finalTranscript.text,
          confidence: input.speech.finalTranscript.confidence,
        },
        latestSnapshot: snapshot,
        recentResults: recentResults(observations),
        // Deictic words pre-bound to the surface pointed at as they were spoken
        // (KD5) — the model acts on these instead of guessing a single target.
        boundReferents: boundReferentsFor(input),
        candidateSurfaces: candidateSurfacesFor(input, input.pointingEvidence),
        availableTools: toolMenu(tools),
      }),
    },
  ];
}
