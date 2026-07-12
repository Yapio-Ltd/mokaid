import { ExternalLink, ShieldAlert, Sparkles, ThumbsDown, ThumbsUp, Undo2 } from "lucide-react";
import { useEffect } from "react";
import { useApproveTaskAction, useTask, useUpdateTask } from "@/api/hooks";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import {
  useReviewQueueStore,
  type ReviewKind,
} from "@/stores/review-queue-store";
import { useUiStore } from "@/stores/ui-store";

/** Blocking gate for in_review + mid-run tool approvals. */
export function ReviewGateModal() {
  const queue = useReviewQueueStore((s) => s.queue);
  const modalOpen = useReviewQueueStore((s) => s.modalOpen);
  const snooze = useReviewQueueStore((s) => s.snooze);
  const dequeue = useReviewQueueStore((s) => s.dequeue);
  const updateItem = useReviewQueueStore((s) => s.updateItem);
  const selectTask = useUiStore((s) => s.selectTask);

  const current = queue[0] ?? null;
  const { data: taskEnvelope } = useTask(current?.taskId ?? null);
  const task = taskEnvelope?.data;
  const updateTask = useUpdateTask();
  const approveAction = useApproveTaskAction();

  // Keep queue item enriched from live task detail (approval id, copy).
  useEffect(() => {
    if (!current || !task) return;
    if (current.kind === "tool_approval" && task.pending_approval) {
      updateItem(current.taskId, "tool_approval", {
        approvalRequestId: task.pending_approval.id,
        proposedAction: task.pending_approval.proposed_action,
        agentName: task.assigned_agent_name,
        title: task.title,
      });
    } else if (current.kind === "in_review") {
      updateItem(current.taskId, "in_review", {
        agentName: task.assigned_agent_name,
        title: task.title,
      });
    }
  }, [current, task, updateItem]);

  // Drop stale items that no longer need a decision.
  useEffect(() => {
    if (!current || !task) return;
    if (current.kind === "in_review" && task.status !== "in_review") {
      dequeue(current.taskId, "in_review");
      return;
    }
    if (
      current.kind === "tool_approval" &&
      !task.pending_approval &&
      task.latest_run?.status !== "waiting_for_approval"
    ) {
      dequeue(current.taskId, "tool_approval");
    }
  }, [current, task, dequeue]);

  const open = modalOpen && current != null;
  const index = 1;
  const total = queue.length;
  const busy = updateTask.isPending || approveAction.isPending;

  const agentLabel =
    current?.agentName ?? task?.assigned_agent_name ?? "The agent";
  const title = current?.title ?? task?.title ?? "Task";

  const onOpenChange = (next: boolean) => {
    if (!next) snooze();
  };

  const advance = (taskId: string, kind: ReviewKind) => {
    dequeue(taskId, kind);
  };

  const approveReview = () => {
    if (!current) return;
    updateTask.mutate(
      { id: current.taskId, status: "completed" },
      { onSuccess: () => advance(current.taskId, "in_review") },
    );
  };

  const reviseReview = () => {
    if (!current) return;
    updateTask.mutate(
      { id: current.taskId, status: "in_progress" },
      { onSuccess: () => advance(current.taskId, "in_review") },
    );
  };

  const decideTool = (decision: "approved" | "rejected") => {
    if (!current) return;
    const approvalRequestId =
      current.approvalRequestId ?? task?.pending_approval?.id ?? null;
    if (!approvalRequestId) return;
    approveAction.mutate(
      { taskId: current.taskId, approvalRequestId, decision },
      { onSuccess: () => advance(current.taskId, "tool_approval") },
    );
  };

  const openDetails = () => {
    if (!current) return;
    selectTask(current.taskId);
    snooze();
  };

  if (!current) return null;

  const pending = task?.pending_approval;
  const descriptionPreview =
    current.kind === "tool_approval"
      ? current.proposedAction ?? pending?.proposed_action ?? "The agent needs your go-ahead before continuing."
      : task?.description?.trim() ||
        "The agent finished. Review the output, then approve or send it back for revisions.";

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title={current.kind === "tool_approval" ? "Approval needed" : "Validation required"}
      description={`${index} of ${total} pending`}
      className="w-[560px] border border-warning/40 shadow-[0_0_0_1px_rgba(245,158,11,0.25)]"
      footer={
        current.kind === "in_review" ? (
          <>
            <Button variant="secondary" size="sm" className="gap-1.5" disabled={busy} onClick={reviseReview}>
              <Undo2 size={12} /> Revise
            </Button>
            <Button size="sm" className="gap-1.5" loading={updateTask.isPending} onClick={approveReview}>
              <ThumbsUp size={12} /> Approve
            </Button>
          </>
        ) : (
          <>
            <Button
              variant="secondary"
              size="sm"
              className="gap-1.5"
              disabled={busy || !(current.approvalRequestId || pending?.id)}
              onClick={() => decideTool("rejected")}
            >
              <ThumbsDown size={12} /> Reject
            </Button>
            <Button
              size="sm"
              className="gap-1.5"
              loading={approveAction.isPending}
              disabled={!(current.approvalRequestId || pending?.id)}
              onClick={() => decideTool("approved")}
            >
              <ThumbsUp size={12} /> Approve
            </Button>
          </>
        )
      }
    >
      <div className="space-y-4">
        <div
          className={
            current.kind === "tool_approval"
              ? "rounded-xl bg-warning/10 px-4 py-3.5"
              : "rounded-xl bg-warning/10 px-4 py-3.5"
          }
        >
          <div className="flex items-start gap-2.5">
            {current.kind === "tool_approval" ? (
              <ShieldAlert size={16} className="mt-0.5 shrink-0 text-warning" />
            ) : (
              <Sparkles size={16} className="mt-0.5 shrink-0 text-warning" />
            )}
            <div className="min-w-0 flex-1">
              <p className="text-[13px] font-semibold text-text">{title}</p>
              <p className="mt-0.5 text-[11px] text-text-secondary">
                {current.kind === "tool_approval"
                  ? `${agentLabel} is waiting for your go-ahead`
                  : `${agentLabel} finished — approve or request changes`}
              </p>
              {current.kind === "tool_approval" && pending && (
                <div className="mt-2 flex flex-wrap items-center gap-1.5">
                  <Badge tone="muted">{pending.tool_name}</Badge>
                  <span
                    className={
                      "rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide " +
                      (["high", "critical"].includes(pending.risk_level)
                        ? "bg-danger/15 text-danger"
                        : "bg-warning/15 text-warning")
                    }
                  >
                    {pending.risk_level} risk
                  </span>
                </div>
              )}
            </div>
          </div>
        </div>

        <p className="text-[12px] leading-relaxed text-text-secondary line-clamp-6">
          {descriptionPreview}
        </p>

        <button
          type="button"
          onClick={openDetails}
          className="inline-flex items-center gap-1.5 text-[11px] font-medium text-primary-light transition-colors hover:text-primary"
        >
          <ExternalLink size={12} /> View full task details
        </button>
      </div>
    </Dialog>
  );
}
