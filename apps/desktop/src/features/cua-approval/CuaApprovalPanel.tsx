import type { PendingApproval } from "@handsoff/cua";

type CuaApprovalPanelProps = {
  pending?: readonly PendingApproval[];
  onApprove?: (id: string) => void;
  onDeny?: (id: string) => void;
};

export function CuaApprovalPanel(_props: CuaApprovalPanelProps) {
  void _props.pending;
  throw new Error("not implemented");
}
