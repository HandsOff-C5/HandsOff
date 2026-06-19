type EmptyPanelProps = {
  title: string;
  message: string;
};

// Shared empty-state card. Each core-loop concern renders one as a mount point
// for the lane that fills it in later (sessions #49, plan preview #38, etc.).
export function EmptyPanel({ title, message }: EmptyPanelProps) {
  return (
    <section className="panel">
      <h2 className="panel__title">{title}</h2>
      <p className="panel__empty">{message}</p>
    </section>
  );
}
