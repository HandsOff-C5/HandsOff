# Director Right-Edge Rail — Implementation Spec

_Extracted from HandsOff-Knowledge/Claude-Design_Director (Foundations + Flow 2/3 + support.js + design.md) via research workflow, 2026-06-25._

I'll synthesize the extracts into one implementation-ready spec. Let me first reconcile a key tension I'm noticing across the sources, then produce the spec.

The extracts contain three slightly different value sets for the rail: the **Foundations static board** (34px marks, 26px radius, static bars), the **Flow 3 live demo** (36px marks, 28px radius, animated `dgWave`/`dgRing`), and the **canonical `design.md` token system** (gold `#D4A018`, light-first, `glass-hud`). For a build spec, the live demo (Flow 3) is the truest behavioral reference and the canonical `design.md` is the token authority, so I'll lead with those and flag where Foundations differs.

---

# Director — Right-Edge Rail: Implementation Spec

**Build target:** an edge-pinned, full-height, click-through `NSPanel` (`.nonactivatingPanel`, `.borderless`) hosting a SwiftUI vertical glass capsule. The panel spans the screen's right edge; only the capsule and its hover-reveal panel accept hits.

**Source reconciliation (read first):** Three renders exist. The **Flow 3 demo** (`Flow 3 - Demo Journey.dc.html`) is the canonical *behavioral* reference — build to its values (36px marks, 28px radius, animated rings/waveform, the `pend` state). The **Foundations board** (`Director Foundations.dc.html`) is a frozen static snapshot — use only to corroborate styling, not for animation. The **canonical `design.md`** is the *token* authority — its gold accent, light-first appearance, `glass-hud` material, motion, and lexicon override anything older. Where they conflict I note it inline and pick Flow 3 + canonical tokens.

---

## 1. VISUAL SPEC

### 1.1 The container (glass pill capsule)

| Property | Value | Source |
|---|---|---|
| Shape | Vertical stadium/capsule, fully rounded ends | rail-images, rail-spec |
| Corner radius | **28px** (Flow 3) / 26px (Foundations) — use **28px** | rail-behavior, rail-spec |
| Width | Intrinsic — hugs the 36px marks + 8px L/R padding ≈ **52px** (image ref reads ~55–60px) | rail-spec, rail-images |
| Height | Auto — vertical flex, grows with content; image ref ≈ **215px** for 3 marks | rail-images |
| Padding | **13px top/bottom, 8px left/right** | rail-behavior, rail-spec |
| Internal layout | `VStack`, center-aligned, **11px** spacing between sections | rail-behavior |
| Offset from edge | **12px** inset from the right screen edge (`margin-right:12px`) | rail-behavior |
| Vertical position | Centered vertically on the screen | rail-behavior, rail-images |

**Glass material** — use canonical `glass-hud` (override Flow 3's raw `var(--winhud)` mix; prefer native):

- **Native (preferred):** `NSVisualEffectView` material `.hudWindow`, `state = .active`, `blendingMode = .behindWindow`. Lets the OS handle light/dark + wallpaper tint and `prefers-reduced-transparency` natively. (tokens-voice)
- **Hand-mixed fallback (`glass-hud`):**
  - Light: `background rgba(250,250,252,0.70)`, `backdrop-filter blur(28px) saturate(180%)`, `border 1px rgba(0,0,0,0.12)`, `box-shadow 0 12px 40px rgba(0,0,0,0.18)`
  - Dark: `background rgba(30,30,32,0.72)`, same blur/sat, `border 1px rgba(255,255,255,0.12)`, `box-shadow 0 12px 40px rgba(0,0,0,0.55)`
  - (tokens-voice — `shadow-pop`. Flow 3's literal shadow was `0 12px 40px rgba(0,0,0,0.22)`; canonical `shadow-pop` supersedes.)
- **Rules:** never animate `backdrop-filter`; cap ≤3–4 blur surfaces; no glass-on-glass. (tokens-voice)

**Section stack (top → bottom):** LIVE pip → hairline separator → cursor-marks column → hairline separator → expand button.

### 1.2 Top LIVE pip (waveform + label)

A `VStack` (7px gap in Flow 3 / 6px in Foundations — use **7px**), hidden by default (`display:none` → SwiftUI `.opacity(0)`/conditional), shown only while listening (§2.1).

- **Waveform:** **3 vertical bars**, each `width 3px`, `gap 2.5px`, container `height 18px` (Flow 3) — bottom-aligned (equalizer grows upward). Color = `accent #D4A018`. Bar radius `2px`.
  - *Animation (Flow 3):* each bar runs `dgWave` — `height 5px ↔ 18px`, **0.9s ease-in-out infinite**, staggered start delays **0s / 0.15s / 0.3s**. (rail-behavior, rail-logic)
  - *Foundations static variant:* bars fixed at `[8,15,11]px`, 16px container, no animation — that's the frozen board, not the build target.
- **"LIVE" label:** text `LIVE`, `font-size 8px`, `font-weight 700`, `letter-spacing 0.07em`, color `accent` (in canonical accent-on-surface terms: `#8A6D0F` light / `#E6C265` dark for AA contrast on the glass — Foundations used `accentOn`; Flow 3 used raw `var(--acc)`). **Recommendation: use `accent-on-surface`** for contrast safety. (rail-spec, tokens-voice)
- **Family:** Inter (UI). Inherited.

### 1.3 Hairline separators

Two, one under the LIVE pip and one above the expand button:

- Width **20px** (inset, narrower than pill → centered), height **1px**, color = `separator` token (`rgba(0,0,0,0.08)` light / `rgba(255,255,255,0.09)` dark). (rail-spec, tokens-voice)

### 1.4 Cursor-mark circles (the agent column)

A `VStack`, center-aligned, **11px** spacing. Each mark:

| Property | Value | Source |
|---|---|---|
| Diameter | **36×36px** (Flow 3) / 34px (Foundations) — use **36px** | rail-behavior, rail-logic |
| Shape | Full circle (`border-radius:50%`) | rail-spec |
| Border | **1.5px solid** status color | rail-behavior |
| Fill (tint) | Status color at **14% alpha** | rail-behavior |
| Inner glyph | Director arrowhead SVG, `viewBox 0 0 51 54`, rendered **15×16px** (Flow 3) / 14×15 (Foundations) | rail-behavior |
| Glyph path | `M4 2L14.7986 47.2052L23.5954 25.3528L46.6433 20.4843L4 2Z` | rail-spec |
| Glyph keyline | `fill` = status color; `stroke #fff`, `stroke-width 2`, `stroke-linejoin round`, `paint-order stroke` (white keyline painted *under* fill — the signature mark) | rail-spec, rail-images |
| Native tooltip | `title="Intent NN"` → SwiftUI `.help("Intent NN")` | rail-behavior |

**Per-state styling** (Flow 3 — note Flow 3 adds a third `pend` state that Foundations lacks):

| State | `status` | Border | Tint fill | Glyph fill | Ring | Badge |
|---|---|---|---|---|---|---|
| **Running** | `run` | `#D4A018` gold (`--acc`) | `rgba(212,160,24,0.14)` | `#D4A018` | **Yes** — pulsing | none |
| **Needs Greenlight** | `pend` | `#FF9F0A` amber (`--on-warn`) | `rgba(255,159,10,0.14)` | `#FF9F0A` | none | none |
| **Complete** | `done` | `#32D75F` green (`--on-ok`) | `rgba(50,215,95,0.14)` | `#32D75F` | none | **green ✓ badge** |

- **Running ring:** absolutely-positioned circle, `inset -2px` (just outside the 36px circle), `1.5px solid #D4A018`. *Animated* via `dgRing`: `scale 0.5 → 2.1`, `opacity 0.9 → 0`, **1.6s ease-out infinite** (radar-ping). (Foundations renders this static at `opacity 0.45` — animate it for the build.) (rail-behavior, rail-logic)
- **Complete ✓ badge:** **14×14px** (Flow 3) / 13px (Foundations) green `#32D75F` disc pinned bottom-right at `right:-3px; bottom:-3px`, containing a filled white Material Symbols `check` glyph (`font-variation-settings:'FILL' 1`), `font-size 12px` (Flow 3) / 11px. (rail-behavior)
- **No idle/dimmed mark state exists** — marks are only run/pend/done. (rail-spec)

> **One-accent caution (tokens-voice):** "one accent per view." If multiple marks are running, gold proliferates. Confirm with user whether all running marks pulse gold, or only the single one needing attention (see Open Questions).

### 1.5 Bottom expand button

A circular button below the lower separator:

| Property | Value | Source |
|---|---|---|
| Diameter | **34×34px** (Flow 3) / 32px (Foundations) — use **34px** | rail-behavior, rail-spec |
| Shape | Circle | rail-spec |
| Background | `control-bg` / `var(--soft)` (`rgba(0,0,0,0.05)` light / `rgba(255,255,255,0.06)` dark) | rail-spec, tokens-voice |
| Border | **1px solid** `border` token | rail-spec |
| Icon | Material Symbols Rounded **`open_in_full`** (diagonal expand arrows, the ⤢/↗ affordance), `font-size 18px` (Flow 3) / 16px, color `text-secondary` | rail-behavior, rail-spec |
| Tooltip | `title="Open Home"` → `.help("Open Home")` | rail-behavior |
| Hover | Background → `separator` token, `transition background 0.2s` | rail-behavior |

> The icon is the Material glyph `open_in_full`, not a literal `⤢` codepoint; captions describe it as `↗`. (rail-spec)

---

## 2. MICRO-INTERACTION CATALOG

> Timing/easing baseline (canonical motion, tokens-voice): standard easing `cubic-bezier(0.16, 1, 0.3, 1)`, standard duration 0.3–0.4s. Looping motion (`dgWave`, `dgRing`) is pure CSS keyframe in the prototype → use repeating SwiftUI animations.

**1. Hold-`fn` listening → LIVE pip on**
 *Trigger:* user holds the `fn` key and begins speaking an intent.
 *What happens:* the top LIVE pip section becomes visible — 3-bar waveform + "LIVE" label appear above the marks. (In Flow 3 this is an instant `display:none → flex` swap driven by `syncRailListen()`.)
 *Animation/timing:* **instant** show/hide (no fade in the prototype). Once visible, the 3 bars run `dgWave` (height 5↔18px, 0.9s ease-in-out infinite, staggered 0/0.15/0.3s). (rail-behavior)

**2. Utterance captured / not-listening → LIVE pip off**
 *Trigger:* utterance ends / Director stops listening.
 *What happens:* LIVE pip section collapses to nothing; marks/expand reflow upward.
 *Animation/timing:* **instant** collapse (no fade). (rail-behavior)

**3. Agent added (new intent issued)**
 *Trigger:* a new intent is dispatched (the agent list gains an entry).
 *What happens:* a new cursor-mark appears at the bottom of the column in its initial state (`run`, or `pend` if awaiting Greenlight).
 *Animation/timing:* in the prototype this is a wholesale `innerHTML` re-render — **no per-mark enter transition**. *Build recommendation:* add a subtle insert (e.g. `dgGlide`-style `translateY + opacity`, ~0.3–0.4s, standard easing) — flag as a build-add, not in the prototype. (rail-behavior, rail-logic; Open Questions)

**4. Agent running**
 *Trigger:* mark status = `run`.
 *What happens:* gold border + 14% gold tint + gold arrowhead, **plus** an outer pulsing gold ring.
 *Animation/timing:* ring `dgRing` — scale 0.5→2.1, opacity 0.9→0, **1.6s ease-out infinite**. (rail-behavior)

**5. Agent needs Greenlight**
 *Trigger:* mark status = `pend` (plan ready, awaiting approval).
 *What happens:* amber `#FF9F0A` border + tint + arrowhead. **No ring, no badge.**
 *Animation/timing:* static (no animation). (rail-behavior)

**6. Agent complete (green + ✓)**
 *Trigger:* mark status flips to `done`.
 *What happens:* recolors green `#32D75F` (border/tint/glyph), the pulsing ring disappears (gated on `run`), and a green ✓ badge appears bottom-right.
 *Animation/timing:* in the prototype this is an **in-place recolor** on the next render — no transition. *Build recommendation:* cross-fade the recolor + pop-in the badge (~0.3s). The canonical "poof" (cursor dissolve: opacity→0, blur 0→8px, scale 1→1.5, 0.5s + particle burst) belongs to the **roaming cursor sprite at completion**, NOT to the rail mark — the rail mark persists. (rail-behavior, tokens-voice)

**7. Agent removal ("poof")**
 *Trigger:* — *(none in the prototype)*.
 *What happens:* **Completed marks are NOT removed and there is no poof on the rail.** Marks only leave when the entire rail unmounts (dashboard opens, step ≥10). The `poof`/`dissolve` keyframes do not exist for the rail. (rail-behavior, rail-logic) — flag in Open Questions whether the product should ever evict completed marks.

**8. Hover mark / hover rail → intention reveal**
 *Trigger:* pointer enters the rail capsule *or* the reveal panel (`onMouseEnter`).
 *What happens:* an "Intentions" card stack slides in to the **left** of the capsule. Panel: positioned `right:78px; top:40px`, **width 300px**; header label **"INTENTIONS"** (`font-size 10px`, `weight 600`, `letter-spacing 0.08em`, uppercase, `text-tertiary`) over a `VStack` of cards (`gap 10px`). One card per active intent, mirroring the marks:
  - card glass: `card` token + `blur(28px) saturate(180%)`, `border 1px`, **radius 11px**, `padding 13px`, shadow `0 8px 26px rgba(0,0,0,0.18)`
  - card content: 2-digit gold index (`01`/`02`/`03`), agent-identity pill (mono icon + name: **Claude / Claude Code / Codex**), a status pill (Running/Needs Greenlight/Complete with leading colored dot), a title, and a subtitle of current work (e.g. "Reading & labeling via CUA…", "Plan ready — awaiting Greenlight", "Fix written · PR #51 opened").
 *Animation/timing:* panel transitions `opacity 0→1` and `translateX(14px→0)` over **0.22s ease** (fade + slide-in from right). Both capsule and panel share enter/leave handlers (hover bridge across the 78px gap). (rail-behavior)

**9. Hover leave → intention reveal hides**
 *Trigger:* pointer leaves both capsule and panel (`onMouseLeave`).
 *What happens:* after a **160ms grace delay** (cancels if you re-enter), the panel fades + slides back out to `opacity 0`, `translateX(14px)`, `pointer-events:none`.
 *Animation/timing:* 160ms delay, then 0.22s ease reverse. The grace + shared handlers prevent flicker while traveling capsule→cards. (rail-behavior, rail-logic)

**10. Native tooltip on mark (OS-level)**
 *Trigger:* hover a single mark (independent of the reveal panel).
 *What happens:* OS tooltip `Intent NN`. *Timing:* standard macOS tooltip delay. (rail-behavior)

**11. Click mark**
 *Trigger:* click a cursor-mark.
 *What happens:* **No dedicated click handler exists in the prototype** — marks are non-interactive beyond hover/tooltip. *Recommendation:* wire click → focus that agent / open its detail (e.g. select in Home, or hug-cursor to its target). Flag in Open Questions. (rail-behavior)

**12. Click ⤢ expand button → open Home**
 *Trigger:* click the bottom `open_in_full` button (`openDash`).
 *What happens:* the rail (and scene) tear down and the full **Home / Mission Control** dashboard mounts (Flow 3: jump to step 10; `showDash` mounts, `showRail` unmounts). Functionally identical to the menu-bar "Open Home / ⇧⌘M" item.
 *Animation/timing:* dashboard enters with `dgFade 0.4s ease` (canonical window entry: scale 0.95→1 + translateY 10→0, 0.4s, standard easing). Button itself: hover bg `transition 0.2s`. (rail-behavior, tokens-voice)

**13. Edge pin (default right) + onboarding choice**
 *Trigger:* onboarding Step 3 ("Ready") segmented control "Listening panel edge" — Left edge / Right edge; **Right is pre-selected default**.
 *What happens:* writes `localStorage['director.listenEdge']` = `left`|`right`; the active segment swaps to the highlighted style.
 *Critical caveat:* in the prototype this preference moves **only the separate Listening HUD**, NOT the rail — the **rail is hard-pinned right** (`right:0`). HUD goes `left:28px` if left, else `right:82px` (inset to clear the rail). (rail-behavior, rail-logic) — For the product, decide whether the rail should also honor this edge (Open Questions).
 *Animation/timing:* instant on click; preference persists across launches.

**14. Keyboard**
 The rail has no dedicated keys. In the demo, ArrowRight/ArrowLeft drive the scripted journey (`go(±1)`) — that's prototype scaffolding, not a product binding. (rail-logic)

---

## 3. STATES & DATA

**Per cursor-mark (data model):**

| Field | Type | Example | Notes |
|---|---|---|---|
| `id` / index | 2-digit string | `"01"`, `"02"`, `"03"` | Drives gold index in reveal card + `title="Intent NN"` |
| `status` | enum | `run` \| `pend` \| `done` | Drives all per-state styling (§1.4) |
| `executor` | enum/string | `Claude` \| `Claude Code` \| `Codex` (\| `Gemini CLI`) | Mono label + monochrome icon in reveal card |
| `executorIcon` | Material symbol | `search` / `terminal` / `travel_explore` | Per agent in reveal card |
| `title` | string | "Triage issue #42" | Card title; lexicon term: a saved task = **Brief** |
| `intention` / subtitle | string | "Reading & labeling via CUA…" / "Plan ready — awaiting Greenlight" / "Fix written · PR #51 opened" | The hover-reveal "intention" text; varies by status |
| `statusLabel` | string | "Running" / "Needs Greenlight" / "Complete" | Exact pill strings (tokens-voice lexicon) |

**Rail-level state:**

- `isListening: Bool` — drives LIVE pip on/off (true only while holding `fn`/speaking).
- `marks: [Mark]` — ordered; column renders all known intents for the current moment; marks accumulate and flip in order, never auto-removed.
- `listenEdge: enum {left, right}` — persisted (`director.listenEdge`, default `right`); currently positions the HUD, not the rail.
- `appTheme` — persisted (`director.appTheme`); light default, follows system, manual override.

**Counts / status vocabulary (tokens-voice):** segment/count copy uses `"All 6" · "Running 2" · "Needs you 1"` (mono number, dimmer). Status pill recipe = 16% alpha fill of status color + matching solid text + 5px leading dot, radius 6px. Status colors: Running `#D4A018`, Needs Greenlight `#FF9F0A`, Complete `#32D75F`, Paused → `warning` (orange; optionally lower-chroma to distinguish), Reject/destructive `#FF453A`.

---

## 4. POSITIONING

- **Host panel:** full-height container pinned to the right edge — `position:absolute; right:0; top:0; bottom:0; width:420px; z-index:46`. The whole strip is **`pointer-events:none` (click-through)**; only the capsule and reveal panel re-enable hits (`pointer-events:auto`). As an `NSPanel`: non-activating, borderless, `ignoresMouseEvents` on the container with the capsule subview accepting hits (or a tight hit region around the capsule). (rail-behavior, rail-logic)
- **Capsule placement:** **12px** inset from the right edge (`margin-right:12px`), **vertically centered** (`align-items:center; justify-content:flex-end` on the strip → flush-right, centered). (rail-behavior, rail-images)
- **Reveal panel:** to the capsule's left at `right:78px; top:40px`, width 300px. (rail-behavior)
- **Default edge:** **right.** The rail is hard-pinned right in the prototype; `director.listenEdge` repositions only the Listening HUD. (rail-behavior, rail-logic)
- **Spaces / displays:** not specified in the extracts. *Build default (recommend):* `NSPanel` with `collectionBehavior` = `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]` so the rail rides along across Spaces and over full-screen apps; pin to the screen carrying the active/menu-bar display, recompute frame on `NSApplication.didChangeScreenParametersNotification`. Flag in Open Questions (no source guidance).

---

## 5. RELATIONSHIP TO OTHER SURFACES

The rail is the **always-on, minimal** summary surface. In the Flow 3 demo its visibility is gated `step ≥ 2 && ≤ 9` (present from first intent through last confirm; gone on intro and once Home opens). Surface-by-surface:

| Surface | When shown | Relationship to rail |
|---|---|---|
| **Right-edge rail** | Always-on while agents exist / Director is active (demo: steps 2–9) | The persistent spine; summarizes everything below into marks + LIVE pip. |
| **Wide LISTENING HUD** (transcript / referents / Greenlight) | While holding `fn` to speak (demo: steps 2/3/5, `showHud`) | Separate floating panel, edge-configurable (`listenEdge`: `left:28px` or `right:82px`, inset to clear the rail). The rail's LIVE pip is the *minimal* echo of this HUD's richer "LISTENING" treatment. Enters `dgFade 0.3s`, vertically centered. |
| **Gaze / focus brackets** | Around the agent's current target (cursor-style option C; brand mark uses the eye-gaze corner brackets) | Marks the on-screen *target*; the rail marks the *agent roster*. Complementary, different planes. |
| **Hug-cursor / roaming reticle** | While an agent acts on screen (demo: steps 2–6, `showCursor`) | The big gold arrowhead that `dgGlide`s (0.5s) to its target with a `dgRing` (1.7s) pulse and a label chip. This sprite is what does the completion **"poof"** (dissolve, 0.5s). The rail's small marks are the *stationary roster mirror* of this roaming cursor — same arrowhead glyph, miniaturized. |
| **Home / Mission Control dashboard** | On ⤢ expand (or menu "Open Home / ⇧⌘M") — demo step ≥10 | The rail's expanded form. Opening it **unmounts the rail** (they're mutually exclusive in the demo). Same status vocabulary (Running/Needs Greenlight/Complete pills) the rail compresses into colored marks. |
| **Reveal "Intentions" card stack** | On rail hover (§2.8) | The rail's own progressive disclosure — one card per mark, shown left of the capsule. |
| **Menu-bar status icon** | Always (gold cursor in menu bar) | The collapsed always-on presence; its menu's "Open Home" shares the rail's `openDash` action verbatim. |

---

## 6. OPEN QUESTIONS

1. **Rail edge configurability.** In the prototype the rail is hard-pinned right and `director.listenEdge` moves only the Listening HUD. Should the *rail itself* also honor the left/right preference, or stay right-only with the HUD as the only edge-switchable surface? (The onboarding copy explicitly scopes the choice to "the HUD," so right-only-rail is the literal reading.)

2. **Completed-mark eviction.** There is intentionally **no removal/poof** on the rail — completed marks persist green+✓ until the whole rail unmounts. For a long-running real product the column could grow unbounded. Confirm: persist all completed marks, auto-evict after a delay, cap to N most-recent, or collapse completed into a count? (No source guidance.)

3. **Click-mark behavior.** Marks have no click action in the prototype (hover/tooltip only). What should clicking a mark do — focus that agent, open its detail card, hug-cursor to its target, or open Home scrolled to it?

4. **One-accent vs. multiple running golds.** Canonical says "one accent per view," but the demo paints *every* running mark gold with a pulsing ring (e.g. step 6 = 3 simultaneous gold rings). Confirm whether all running marks pulse, or only the single one needing attention pulses while others sit calm.

5. **Mark enter/exit transitions.** The prototype re-renders wholesale (no per-mark animation). Approve adding subtle insert (translateY+fade ~0.3s) and complete-recolor cross-fade for product polish, or keep the instant swap?

6. **Spaces / multi-display behavior.** No source spec. Confirm the recommended defaults: ride all Spaces + full-screen apps (`.canJoinAllSpaces`, `.fullScreenAuxiliary`), follow the active/menu-bar display, re-pin on screen-config change.

7. **LIVE pip transition.** Prototype toggles the pip instantly (no fade). Keep instant, or add a short fade to feel less abrupt? (Note: `prefers-reduced-motion` must keep it instant regardless.)

8. **Reduced-motion / reduced-transparency.** Canonical mandates: under `prefers-reduced-motion`, kill `dgRing`/`dgWave` and all transforms (marks resolve to end state, no pulsing ring, no waveform animation); under `prefers-reduced-transparency`, swap glass for an opaque fill (native `NSVisualEffectView` handles this; hand-mixed fallback needs `window`/`canvas` opaque bg + same border/shadow). Confirm this is in-scope for v1.

9. **Value set confirmation.** I built to Flow 3's live values (36px marks, 28px radius, animated rings, 18px expand icon, the `pend` state) over the Foundations static board (34px / 26px / static / no `pend`). Confirm Flow 3 is the intended build reference.

**Key source files:**
- `/Users/jasondijols/Documents/Code-Projects/Capstone/HandsOff-Knowledge/Claude-Design_Director/Flow 3 - Demo Journey.dc.html` (behavioral truth: rail markup, `railAgents`/`renderRailMarks`/`syncRailListen`/`renderCards`, `railEnter`/`railLeave`/`openDash`, `edge`/`placeHud`)
- `/Users/jasondijols/Documents/Code-Projects/Capstone/HandsOff-Knowledge/Claude-Design_Director/Flow 2 - First Run.dc.html` (onboarding edge chooser, `pickLeft`/`pickRight`/`setEdge`)
- `/Users/jasondijols/Documents/Code-Projects/Capstone/HandsOff-Knowledge/Claude-Design_Director/Director Foundations.dc.html` (static board: `railMark`, `rail`, `wave`)
- `/Users/jasondijols/Documents/Code-Projects/Capstone/HandsOff-Knowledge/Claude-Design_Director/design.md` (canonical tokens, materials, motion, lexicon) + `uploads/design.md` (superseded; motion source) + `uploads/brand.md` (lexicon)
- `/Users/jasondijols/Documents/Code-Projects/Capstone/HandsOff-Knowledge/Claude-Design_Director/refs/01-rail-hover.png` (canonical rail render)