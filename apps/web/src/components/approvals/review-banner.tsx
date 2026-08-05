import { ArrowRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useReviewQueueStore } from "@/stores/review-queue-store";

/** Slim attention strip while reviews are pending and the gate is snoozed. */
export function ReviewBanner() {
  const queue = useReviewQueueStore((s) => s.queue);
  const modalOpen = useReviewQueueStore((s) => s.modalOpen);
  const open = useReviewQueueStore((s) => s.open);

  if (queue.length === 0 || modalOpen) return null;

  const count = queue.length;
  const label = count === 1 ? "task awaits validation" : "tasks await validation";

  return (
    <div
      role="status"
      className="relative flex shrink-0 items-center gap-3 border-b border-primary/15 bg-primary/[0.06] px-4 py-2 backdrop-blur-sm"
    >
      {/* Soft left accent — attention without the amber alarm strip */}
      <span
        aria-hidden
        className="absolute inset-y-0 left-0 w-px bg-gradient-to-b from-transparent via-primary to-transparent opacity-80"
      />

      <span className="relative inline-flex h-6 min-w-6 shrink-0 items-center justify-center rounded-md bg-primary/15 px-1.5 text-[11px] font-semibold tabular-nums tracking-tight text-primary-light ring-1 ring-primary/25">
        <span
          aria-hidden
          className="absolute inset-0 rounded-md bg-primary/20 opacity-60 animate-pulse"
        />
        <span className="relative">{count}</span>
      </span>

      <p className="min-w-0 flex-1 truncate text-[12px] leading-none">
        <span className="font-medium text-text">
          {count} {label}
        </span>
        <span className="ml-2 hidden font-normal text-text-muted sm:inline">
          Review so agents can continue
        </span>
      </p>

      <Button
        size="sm"
        variant="ghost"
        className="h-7 shrink-0 gap-1 px-2.5 text-[12px] text-primary-light hover:bg-primary/10 hover:text-primary-light"
        onClick={() => open()}
      >
        Review
        <ArrowRight size={13} className="opacity-70" />
      </Button>
    </div>
  );
}
