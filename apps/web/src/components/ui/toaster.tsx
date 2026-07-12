import { AlertTriangle, ArrowRight, CheckCircle2, Loader2, Sparkles, X } from "lucide-react";
import { useNavigate } from "@tanstack/react-router";
import { useToastStore, type ToastTone } from "@/stores/toast-store";
import { useReviewQueueStore } from "@/stores/review-queue-store";
import { useUiStore } from "@/stores/ui-store";
import { cn } from "@/lib/cn";

const toneIcon: Record<ToastTone, typeof Sparkles> = {
  info: Sparkles,
  success: CheckCircle2,
  error: AlertTriangle,
  working: Loader2,
  warning: AlertTriangle,
};

const toneClasses: Record<ToastTone, string> = {
  info: "text-primary-light",
  success: "text-success",
  error: "text-danger",
  working: "text-info",
  warning: "text-warning",
};

/** Top-right realtime toast stack (task lifecycle, agent activity…). */
export function Toaster() {
  const toasts = useToastStore((s) => s.toasts);
  const dismiss = useToastStore((s) => s.dismiss);
  const selectTask = useUiStore((s) => s.selectTask);
  const openReview = useReviewQueueStore((s) => s.open);
  const enqueueReview = useReviewQueueStore((s) => s.enqueue);
  const navigate = useNavigate();

  if (toasts.length === 0) return null;

  return (
    <div className="pointer-events-none fixed top-[72px] right-5 z-[90] flex w-80 flex-col-reverse gap-2">
      {toasts.map((toast) => {
        const Icon = toneIcon[toast.tone];
        const clickable = toast.taskId != null;
        return (
          <div
            key={toast.id}
            role="status"
            onClick={
              clickable
                ? () => {
                    dismiss(toast.id);
                    const taskId = toast.taskId!;
                    if (toast.tone === "warning") {
                      const store = useReviewQueueStore.getState();
                      if (!store.queue.some((q) => q.taskId === taskId)) {
                        enqueueReview(
                          {
                            taskId,
                            kind: toast.title.toLowerCase().includes("approval")
                              ? "tool_approval"
                              : "in_review",
                            title: toast.description?.replace(/^"|"$/g, "") || toast.title,
                          },
                          { open: true },
                        );
                      } else {
                        openReview();
                      }
                      return;
                    }
                    selectTask(taskId);
                    navigate({ to: "/tasks" });
                  }
                : undefined
            }
            className={cn(
              "mk-toast-in pointer-events-auto flex items-start gap-2.5 rounded-lg border border-border bg-surface-overlay px-3 py-2.5 shadow-lg",
              clickable && "cursor-pointer transition-colors hover:border-primary/50",
            )}
          >
            <Icon
              size={15}
              className={cn(
                "mt-0.5 shrink-0",
                toneClasses[toast.tone],
                toast.tone === "working" && "animate-spin",
              )}
            />
            <div className="min-w-0 flex-1">
              <p className="text-xs font-semibold text-text">{toast.title}</p>
              {toast.description && (
                <p className="mt-0.5 line-clamp-2 text-[11px] text-text-secondary">
                  {toast.description}
                </p>
              )}
              {clickable && (
                <p className="mt-1 flex items-center gap-1 text-[10px] font-medium text-primary-light">
                  Open task <ArrowRight size={10} />
                </p>
              )}
            </div>
            <button
              onClick={(e) => {
                e.stopPropagation();
                dismiss(toast.id);
              }}
              className="shrink-0 rounded p-0.5 text-text-muted transition-colors hover:text-text"
              aria-label="Dismiss notification"
            >
              <X size={12} />
            </button>
          </div>
        );
      })}
    </div>
  );
}
