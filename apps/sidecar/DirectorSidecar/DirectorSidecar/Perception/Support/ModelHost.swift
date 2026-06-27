import Foundation

/// The model-picker coordinator (`FR-31`, `OOS-8`). Holds every registered `ModelPlugin` and
/// keeps **exactly one** active at a time; each `FrameSample` is routed ONLY to the active
/// plugin. There is no compositing and no multi-model fan-out in v1 — selecting a model swaps
/// the single active capability wholesale.
///
/// This is the host/coordinator LOGIC only — it does not own the picker UI or per-model HUD
/// wiring (that is the final AppDelegate integration dispatch, deliberately out of this slice).
public final class ModelHost {

    /// The registered plugins, keyed by id, in registration order.
    private let plugins: [ModelPlugin]
    private var index: [LabModelID: Int] = [:]

    /// The id of the single active model. Never nil once constructed with a non-empty set.
    public private(set) var activeID: LabModelID

    /// Build a host over a non-empty plugin set. The FIRST plugin is active by default, so the
    /// invariant "exactly one active" holds from construction. Duplicate ids keep the first.
    public init(plugins: [ModelPlugin]) {
        precondition(!plugins.isEmpty, "ModelHost requires at least one plugin")
        self.plugins = plugins
        for (i, p) in plugins.enumerated() where index[p.id] == nil {
            index[p.id] = i
        }
        self.activeID = plugins[0].id
    }

    /// Switch the active model. A no-op if `id` is not registered (the current active stays
    /// active — the "exactly one" invariant is never broken by an unknown id).
    public func activate(_ id: LabModelID) {
        guard index[id] != nil else { return }
        activeID = id
    }

    /// Route one frame to the active plugin and return its output. Only the active plugin's
    /// `process` runs — the others never see the frame.
    @discardableResult
    public func route(_ frame: FrameSample) -> FrameSample {
        guard let i = index[activeID] else { return frame }
        return plugins[i].process(frame)
    }

    /// The active plugin (for callers that need to reach model-specific output, e.g. the face
    /// pointer's `PointerOutput`). Always non-nil.
    public var active: ModelPlugin {
        plugins[index[activeID] ?? 0]
    }
}
