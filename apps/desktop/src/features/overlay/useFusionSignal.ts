import type { PointingEvidence } from "@handsoff/contracts";
import { fuseEvidence, type EvidenceFusion } from "@handsoff/intent";
import { useEffect, useState } from "react";

// Subscribes the HUD to the main window's per-frame pointing evidence (hand +
// gaze + cursor). Injected so the overlay window passes a Tauri `listen` while
// tests push synchronously. Returns an unsubscribe.
export type FusionListen = (onEvidence: (evidence: PointingEvidence[]) => void) => () => void;

export function useFusionSignal(listen?: FusionListen): EvidenceFusion | null {
  const [fusion, setFusion] = useState<EvidenceFusion | null>(null);

  useEffect(() => {
    if (!listen) return;
    return listen((evidence) => setFusion(fuseEvidence(evidence)));
  }, [listen]);

  return fusion;
}
