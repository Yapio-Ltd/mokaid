import { ShieldAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useReviewQueueStore } from "@/stores/review-queue-store";

/** Sticky warning strip while reviews are pending and the gate is snoozed. */
export function ReviewBanner() {
  const queue = useReviewQueueStore((s) => s.queue);
  const modalOpen = useReviewQueueStore((s) => s.modalOpen);
  const open = useReviewQueueStore((s) => s.open);

  if (queue.length === 0 || modalOpen) return null;

  const count = queue.length;
  const label =
    count === 1
      ? "1 task waiting for your validation"
      : `${count} tasks waiting for your validation`;

  return (
    <div
      role="status"
      className="flex shrink-0 items-center gap-3 border-b border-warning/40 bg-warning/15 px-4 py-2.5"
    >
      <span className="relative flex h-2.5 w-2.5 shrink-0">
        <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-warning opacity-75" />
        <span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-warning" />
      </span>
      <ShieldAlert size={15} className="shrink-0 text-warning" />
      <p className="min-w-0 flex-1 text-[12px] font-semibold text-text">
        {label}
        <span className="ml-1.5 font-normal text-text-secondary">
          Approve or revise so your agents can keep moving.
        </span>
      </p>
      <Button size="sm" className="shrink-0 gap-1.5" onClick={() => open()}>
        Review now
      </Button>
    </div>
  );
}
