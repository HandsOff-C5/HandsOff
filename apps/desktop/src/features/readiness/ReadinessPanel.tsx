import type { CapabilityReadiness } from "@handsoff/contracts";
import { readinessColor } from "@handsoff/desktop";

import { useReadinessProbe } from "./useReadinessProbe";

interface ReadinessPanelProps {
  // When provided, render this report instead of probing the host. Lets the
  // dashboard simulate readiness states (and keeps the panel testable without a
  // native backend). Defaults to the live probe.
  report?: CapabilityReadiness[];
}

// First-run capability readiness (issue #17): a green/yellow/red row per
// capability so the user can see whether HandsOff can see, hear, and act before
// they try to.
export function ReadinessPanel({ report }: ReadinessPanelProps) {
  const live = useReadinessProbe();
  const items = report ?? live;

  return (
    <section className="panel">
      <h2 className="panel__title">Readiness</h2>
      <ul className="readiness">
        {items.map((capability) => {
          const color = readinessColor(capability.level);
          return (
            <li key={capability.id} className="readiness__row">
              <span
                className={`status-dot status-dot--${color}`}
                data-readiness={color}
                role="img"
                aria-label={`${capability.label}: ${capability.status}`}
              />
              <span className="readiness__text">
                <span className="readiness__label">{capability.label}</span>
                <span className="readiness__status">{capability.status}</span>
                {capability.hint ? (
                  <span className="readiness__hint">{capability.hint}</span>
                ) : null}
              </span>
            </li>
          );
        })}
      </ul>
    </section>
  );
}
