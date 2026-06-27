// PointingEventRing — the 300ms fusion window over concurrent pointing events (MIGRATION §4;
// RESEARCH_CONVERGENCE §7).
//
// The concurrent PerceptionBus emits a `PointingEvent` per plugin per frame from per-plugin
// queues; the S4 Aligner fuses a gesture with a voice command only when they fall within a ±300ms
// time window (`fusionWindowMillis`). This ring is that bounded recent-past buffer: an insert
// evicts everything older than the window relative to the NEWEST event seen, and `within(now:)`
// returns the survivors ordered by source time.
//
// Concurrency (I5 — in-process bus, no transport): inserts arrive off multiple plugin queues, so
// the backing store is guarded by a lock. A reference type holds the shared mutable state; reads
// return a sorted snapshot copy, never the live array.

import Dispatch
import Foundation

final class PointingEventRing {

    /// The fusion window: a gesture and a voice command fuse only within ±300ms (Aligner, S4).
    static let fusionWindowMillis: Double = 300

    private let lock = NSLock()
    private var events: [PointingEvent] = []
    private let windowNanos: UInt64

    init(windowMillis: Double = PointingEventRing.fusionWindowMillis) {
        self.windowNanos = UInt64(windowMillis * 1_000_000)
    }

    /// Insert one event and evict everything now older than the window (relative to the newest
    /// source time observed across the current contents).
    func insert(_ event: PointingEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        let newest = events.map { $0.header.tSrc.nanoseconds }.max() ?? event.header.tSrc.nanoseconds
        let cutoff = newest >= windowNanos ? newest - windowNanos : 0
        events.removeAll { $0.header.tSrc.nanoseconds < cutoff }
    }

    /// The events within `window` ms before `now`, ordered by source time ascending. Defaults to
    /// the 300ms fusion window.
    func within(
        window millis: Double? = nil,
        now: MonotonicInstant
    ) -> [PointingEvent] {
        // Default to the ring's OWN configured window, not the global constant, so a ring built
        // with a custom window queries against the same span it evicts on.
        let windowNanos = millis.map { UInt64($0 * 1_000_000) } ?? self.windowNanos
        let cutoff = now.nanoseconds >= windowNanos ? now.nanoseconds - windowNanos : 0
        lock.lock()
        defer { lock.unlock() }
        return events
            .filter { $0.header.tSrc.nanoseconds >= cutoff }
            .sorted { $0.header.tSrc < $1.header.tSrc }
    }

    /// Current retained count (thread-safe), for observability/tests.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }
}
