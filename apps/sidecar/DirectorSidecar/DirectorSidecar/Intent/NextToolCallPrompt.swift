//
//  NextToolCallPrompt.swift
//  DirectorSidecar
//
//  Port of the U3b autonomous-loop prompt in @handsoff/intent src/llm/prompt.ts
//  (`buildNextToolCallMessages` + its `NEXT_TOOL_CALL_SYSTEM_PROMPT`, `snapshotFor`,
//  `recentResults`, `boundReferentsFor`, `candidateSurfacesFor`, `toolMenu`). The user
//  message is a single JSON object (the TS does `JSON.stringify(...)`), so it is assembled
//  as `Contracts.JSONValue` and encoded — the most faithful mirror of "build a JS object,
//  then stringify", with explicit `null` where the TS emits `?? null`.
//
//  Scope: ONLY the next-tool-call prompt is ported (Track C). The legacy 6-kind
//  `buildResolveIntentMessages` is not — nothing native consumes the closed ActionStep path.
//

import Foundation

// `ChatMessage` (the on-the-wire `{ role, content }` model) lives in IntentWorkerClient.swift —
// it is the wire body's content type and carries the multimodal (text + image) content the Worker
// forwards opaquely. `buildMessages` keeps the text-only turns BYTE-IDENTICAL by default; it grows
// two ADDITIVE seams: an optional `screenshot` (U5) makes the user turn multimodal (the JSON payload
// as the text part + the capture as an inline `data:` image part), and the focused/bound app's
// affordance fragment (U11, `AppContextCatalog`) is appended to the system turn when that app is
// known. Neither touches the fusion payload keys (boundReferents / selectionText / candidateSurfaces).

enum NextToolCallPrompt {
    /// How many recent observations of loop memory to send — enough for the model to see its
    /// last action's result and not repeat itself, bounded so a long goal's prompt stays small.
    static let recentObservationLimit = 3

    static let systemPrompt =
        "You are HandsOff's autonomous computer-use agent. You pursue the user's GOAL by " +
        "calling ONE cua-driver tool at a time, observing the result, and continuing across turns " +
        "until the goal is done. You drive a real macOS desktop without stealing keyboard focus.\n" +
        "Each turn you receive: the goal, the latest perception snapshot (the focused window + its " +
        "accessibility elements — each with an `index`, a stable `token`, its `role`/`label`/`value`, " +
        "a `frame` {x,y,w,h} in window pixels, and `parentIndex`/`depth` for tree position — plus the " +
        "window's `pid`/`windowId`), the result of your previous tool call (recover from a failure by " +
        "trying something else — never repeat a failed call), the ranked candidate surfaces, and the " +
        "list of available tools with their JSON-Schema parameters. Use ONLY this supplied state — " +
        "never invent windows, elements, indices, or tokens.\n" +
        "Return status `act` with `tool` (one of the listed tool names) and `args` — the tool's flat " +
        "arguments (matching its parameter schema, e.g. pid, window_id, element_token, direction) " +
        "encoded as a JSON object STRING (JSON.stringify'd, not a nested object). " +
        "Example — for launch_app, args is the string {\"appName\":\"Safari\"}, NOT the bare name Safari. " +
        "Targeting calls (click, type_text, set_value, scroll, press_key, …) MUST cite an element from " +
        "the LATEST snapshot by its `element_token` (preferred — a stable handle) or `element_index`, " +
        "AND its `window_id` and `pid` — never a guessed token/index. Use the element `frame` to reason " +
        "about on-screen layout (relative position, what is above/below/inside what). Combine actions " +
        "across turns: to reveal hidden content, scroll or click a menu open, then act on what appears.\n" +
        "COMPOSE TASKS: when the goal is to produce writing ABOUT what's on screen — summarize, draft, " +
        "rewrite, reword, explain in writing, take notes, list the key points — do NOT hunt the UI. " +
        "(1) READ the source content from the latest snapshot's `elements` (and from `selectionText` " +
        "when the user pointed at a specific passage); (2) GENERATE the finished deliverable yourself " +
        "from that content; (3) WRITE your generated text by calling the `write_note` tool with a " +
        "`title` and the full `text` (or type it into a surface the user explicitly named). NEVER " +
        "`type_text` the user's request verbatim (typing the word \"summarize\" is always wrong), and " +
        "NEVER look for or click a button/menu named after the verb — there is no \"Summarize\" control; " +
        "YOU are the one who composes. If the source text is not actually readable from the snapshot " +
        "(or the pointed `selectionText` is empty), return `clarify` saying you can't read the content " +
        "yet — never invent, guess, or fabricate a summary.\n" +
        "DECOMPOSE a multi-step goal into ordered single-tool steps and carry them across turns — e.g. " +
        "\"scroll this down then summarize it\" is: scroll to reveal the content, observe, then read→" +
        "compose→write. Do the single next step toward the goal each turn, using `recentResults` to " +
        "track what you've already done so you advance instead of restarting. NEVER re-issue a call " +
        "that already failed or no-op'd for this goal (same tool on the same target with no observed " +
        "change in the snapshot): change the target, the approach, or the tool — or `clarify` once you " +
        "are out of distinct options. Don't grind the same action waiting for a different result.\n" +
        "Return status `done` with a `summary` when the goal is already satisfied. Return `clarify` " +
        "or `blocked` with a `reason` only when the target is genuinely ambiguous, impossible, or " +
        "unsafe. Always give a one-line `rationale` for an `act`. Prefer reversible/draft actions; " +
        "the supervisor approves anything that commits (sends/deletes/etc.).\n" +
        "`boundReferents` lists each deictic word the user spoke (this/that/here/…) already RESOLVED " +
        "to the surface they were pointing at WHILE saying it, with a confidence. Trust these over " +
        "your own guess: when the goal says 'type X in this and Y in that', map the first deictic to " +
        "its bound surface and the second to its own — do NOT collapse them to one target or ask for " +
        "clarification when a referent is bound. `candidateSurfaces` carries the same pointing " +
        "`confidence`/`source` per surface so you can pick the strongest when no deictic is bound. " +
        "`selectionText`, when present, is the exact text the user had selected INSIDE the surface they " +
        "pointed at — treat it as the precise source for the 'this'/'that' content (read it, don't re-find it)."

    /// `buildNextToolCallMessages`. Goal + perception snapshot (with element indices) + loop
    /// memory + bound deictic referents + candidates (with pointing confidence/source) + the
    /// full tool menu.
    static func buildMessages(
        _ input: Contracts.IntentInput,
        tools: [DriverToolDefinition],
        screenshot: CuaScreenshot? = nil
    ) -> [ChatMessage] {
        let observations = input.goalSession?.observations ?? []
        let payload: Contracts.JSONValue = .object([
            "goal": .string(input.goalSession?.goal ?? input.finalTranscript.text),
            "transcript": .object([
                "text": .string(input.finalTranscript.text),
                "confidence": .number(input.finalTranscript.confidence),
            ]),
            "latestSnapshot": snapshot(for: observations.last) ?? .null,
            "recentResults": .array(recentResults(observations)),
            "boundReferents": .array(boundReferents(input)),
            "selectionText": string(orNull: input.selectionText),
            "candidateSurfaces": .array(candidateSurfaces(input, evidence: input.pointingEvidence)),
            "availableTools": .array(toolMenu(tools)),
        ])
        return [
            systemMessage(for: input),
            userMessage(text: encode(payload), screenshot: screenshot),
        ]
    }

    // MARK: - Message assembly

    /// The system turn: the static `systemPrompt`, plus the focused/bound app's affordance fragment
    /// (U11) when that app is in `AppContextCatalog`. Unknown (or no) app → exactly `systemPrompt`,
    /// byte-identical to the pre-U11 system turn. The fragment is appended after a blank line and
    /// NEVER touches the user payload — `boundReferents`/`selectionText`/`candidateSurfaces` are the
    /// same whether or not an app matches.
    private static func systemMessage(for input: Contracts.IntentInput) -> ChatMessage {
        guard let fragment = AppContextCatalog.contextFragment(for: focusedAppName(input)) else {
            return ChatMessage(role: "system", content: systemPrompt)
        }
        return ChatMessage(role: "system", content: systemPrompt + "\n\n" + fragment)
    }

    /// The user turn: the encoded JSON payload as the text part, plus the optional `screenshot` as an
    /// inline `data:<mime>;base64,…` image part (U5 vision). With no screenshot it is the legacy
    /// string-content message — byte-identical to the pre-U5 user turn, so the Worker and the
    /// text-only path are unaffected. An over-cap capture degrades GRACEFULLY to the text-only message
    /// (the AX snapshot in `text` still drives the next call) rather than failing the resolve — the
    /// screenshot is an enhancement, never a gate.
    private static func userMessage(text: String, screenshot: CuaScreenshot?) -> ChatMessage {
        guard let screenshot else { return ChatMessage(role: "user", content: text) }
        do {
            return try ChatMessage(role: "user", parts: [
                .text(text),
                .image(base64: screenshot.pngBase64, mimeType: screenshot.mimeType),
            ])
        } catch {
            // IntentWorkerError.imageTooLarge — drop the image, keep the goal/snapshot text turn.
            return ChatMessage(role: "user", content: text)
        }
    }

    /// The application the model is acting in/at, for the U11 app-context lookup: the latest
    /// observation's focused window app (the surface it is driving this tick), else the first
    /// temporally-bound deictic referent's surface app (what the user pointed at), else the top
    /// ranked candidate surface's app. Nil when no surface is known — the system turn then carries no
    /// app section.
    private static func focusedAppName(_ input: Contracts.IntentInput) -> String? {
        if let observation = input.goalSession?.observations.last,
           let surface = observation.state?.surface ?? observation.windows.first {
            return surface.app
        }
        if let bound = input.pointingEvidence.first(where: { $0.source == .fusion })?.surface {
            return bound.app
        }
        return input.surfaceCandidates.first?.app
    }

    // MARK: - Snapshot

    /// The focused window + its accessibility elements from a single observation — the live
    /// snapshot the model must cite element indices from. Null before the first observation.
    private static func snapshot(for observation: Contracts.GoalLoopObservation?) -> Contracts.JSONValue? {
        guard let observation else { return nil }
        guard let surface = observation.state?.surface ?? observation.windows.first else { return nil }
        let elements: [Contracts.JSONValue] = (observation.state?.elements ?? []).map { element in
            var fields: [String: Contracts.JSONValue] = [
                "index": number(orNull: element.index.map(Double.init)),
                "role": string(orNull: element.role),
                "label": string(orNull: element.label),
                "value": string(orNull: element.value),
            ]
            // The driver's per-element geometry + tree position, now surfaced to the model: a stable
            // `token` (prefer over index for addressing), the `frame` for spatial reasoning, and
            // `parentIndex`/`depth` for containment. Included only when present to keep the prompt lean.
            if let token = element.token { fields["token"] = .string(token) }
            if let frame = element.frame {
                fields["frame"] = .object([
                    "x": .number(frame.x), "y": .number(frame.y),
                    "w": .number(frame.width), "h": .number(frame.height),
                ])
            }
            if let parent = element.parentIndex { fields["parentIndex"] = .number(Double(parent)) }
            if let depth = element.depth { fields["depth"] = .number(Double(depth)) }
            return .object(fields)
        }
        return .object([
            "focusedWindow": surfaceObject(surface),
            "elements": .array(elements),
        ])
    }

    /// The recent action results — the loop memory the model needs to recover from a failure
    /// instead of repeating it. Last N observations that carry a previous action.
    private static func recentResults(
        _ observations: [Contracts.GoalLoopObservation]
    ) -> [Contracts.JSONValue] {
        observations.suffix(recentObservationLimit).compactMap { observation in
            guard let previous = observation.previousAction else { return nil }
            let (status, detail): (String, String)
            switch previous.result {
            case let .succeeded(summary, _): (status, detail) = ("succeeded", summary)
            case let .blocked(reason, _): (status, detail) = ("blocked", reason)
            case let .failed(error, _): (status, detail) = ("failed", error)
            }
            return .object([
                "tick": .number(Double(observation.tick)),
                "status": .string(status),
                "detail": .string(detail),
            ])
        }
    }

    // MARK: - Bound referents & candidates

    /// The temporally-bound deictic referents (KD4/KD5): each `fusion` pointing-evidence entry
    /// the binder emitted for a deictic word, carrying the surface it bound to + the confidence.
    private static func boundReferents(_ input: Contracts.IntentInput) -> [Contracts.JSONValue] {
        input.pointingEvidence.compactMap { evidence in
            guard evidence.source == .fusion, let surface = evidence.surface else { return nil }
            return .object([
                "word": string(orNull: deicticWord(from: evidence.strategy)),
                "surfaceId": .string(surface.id),
                "app": .string(surface.app),
                "title": .string(surface.title),
                "confidence": .number(evidence.confidence),
                "strategy": .string(evidence.strategy),
            ])
        }
    }

    /// Recover the deictic word the binder stamped into `temporal-bind:<word>@<ts>`. Null for a
    /// fusion strategy that doesn't follow that shape.
    static func deicticWord(from strategy: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "^temporal-bind:([^@]+)@") else { return nil }
        let range = NSRange(strategy.startIndex..., in: strategy)
        guard let match = regex.firstMatch(in: strategy, range: range),
              let wordRange = Range(match.range(at: 1), in: strategy)
        else { return nil }
        return String(strategy[wordRange])
    }

    /// The candidate surface list, each carrying its pointing confidence + the modality that
    /// produced it (null when no evidence references the surface).
    private static func candidateSurfaces(
        _ input: Contracts.IntentInput,
        evidence: [Contracts.PointingEvidence]
    ) -> [Contracts.JSONValue] {
        input.surfaceCandidates.enumerated().map { index, surface in
            let best = confidence(forSurface: surface.id, evidence: evidence)
            var object = surfaceFields(surface)
            object["rank"] = .number(Double(index + 1))
            object["confidence"] = number(orNull: best?.confidence)
            object["source"] = string(orNull: best?.source.rawValue)
            return .object(object)
        }
    }

    /// The strongest pointing evidence carrying this surface — its confidence + source ground
    /// the candidate so the model can act on deixis instead of guessing.
    private static func confidence(
        forSurface surfaceId: String,
        evidence: [Contracts.PointingEvidence]
    ) -> (confidence: Double, source: Contracts.PointingEvidence.Source)? {
        let best = evidence
            .filter { $0.surface?.id == surfaceId }
            .max { $0.confidence < $1.confidence }
        return best.map { ($0.confidence, $0.source) }
    }

    private static func toolMenu(_ tools: [DriverToolDefinition]) -> [Contracts.JSONValue] {
        tools.map { tool in
            .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.inputSchema.map(bridge(_:)) ?? .null,
            ])
        }
    }

    // MARK: - Surface helpers

    /// A surface as the snapshot's `focusedWindow` (no rank/pointing fields).
    private static func surfaceObject(_ surface: Contracts.SurfaceSnapshot) -> Contracts.JSONValue {
        .object(surfaceFields(surface))
    }

    private static func surfaceFields(_ surface: Contracts.SurfaceSnapshot) -> [String: Contracts.JSONValue] {
        [
            "id": .string(surface.id),
            "title": .string(surface.title),
            "app": .string(surface.app),
            "pid": number(orNull: surface.pid.map(Double.init)),
            "windowId": number(orNull: surface.windowId.map(Double.init)),
            "availability": .string(surface.availability.rawValue),
            "accessStatus": .string(surface.accessStatus.rawValue),
        ]
    }

    // MARK: - JSON plumbing

    private static func number(orNull value: Double?) -> Contracts.JSONValue {
        value.map(Contracts.JSONValue.number) ?? .null
    }

    private static func string(orNull value: String?) -> Contracts.JSONValue {
        value.map(Contracts.JSONValue.string) ?? .null
    }

    /// Bridge the CUA adapter's top-level `JSONValue` (a `DriverToolDefinition.inputSchema`)
    /// into the namespaced `Contracts.JSONValue` used to assemble the payload. The two enums
    /// are intentionally distinct (PORTING.md notes 4/6); the cases map one-to-one.
    private static func bridge(_ value: JSONValue) -> Contracts.JSONValue {
        switch value {
        case .null: return .null
        case let .bool(b): return .bool(b)
        case let .number(n): return .number(n)
        case let .string(s): return .string(s)
        case let .array(a): return .array(a.map(bridge(_:)))
        case let .object(o): return .object(o.mapValues(bridge(_:)))
        }
    }

    private static func encode(_ value: Contracts.JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
