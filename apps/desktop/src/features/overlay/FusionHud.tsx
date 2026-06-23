import type { EvidenceFusion } from "@handsoff/intent";

type FusionHudProps = {
  // The current fusion breakdown to display; null/undefined renders the idle HUD.
  fusion?: EvidenceFusion | null;
};

export function FusionHud(_props: FusionHudProps) {
  void _props.fusion;
  throw new Error("not implemented");
}
