import { useEffect, useRef } from "react";
import { useTasks } from "@/api/hooks";
import {
  useReviewQueueStore,
  type ReviewQueueItem,
} from "@/stores/review-queue-store";

/**
 * Seeds the review queue from existing in_review / waiting tasks on load,
 * then opens the gate so pending validations are not buryable.
 */
export function useReviewQueueHydration() {
  const hydratedRef = useRef(false);
  const hydrate = useReviewQueueStore((s) => s.hydrate);

  const inReview = useTasks({ status: "in_review" });
  const waiting = useTasks({ status: "waiting" });

  useEffect(() => {
    if (hydratedRef.current) return;
    if (inReview.isLoading || waiting.isLoading) return;
    // Wait until both queries have settled (success or error).
    if (!inReview.isFetched || !waiting.isFetched) return;

    hydratedRef.current = true;

    const items: ReviewQueueItem[] = [];

    for (const task of inReview.data?.data ?? []) {
      items.push({
        taskId: task.id,
        kind: "in_review",
        title: task.title,
        agentName: task.assigned_agent_name,
      });
    }

    for (const task of waiting.data?.data ?? []) {
      const runWaiting = task.latest_run?.status === "waiting_for_approval";
      const hasPending = task.pending_approval != null;
      if (!runWaiting && !hasPending) continue;
      items.push({
        taskId: task.id,
        kind: "tool_approval",
        title: task.title,
        agentName: task.assigned_agent_name,
        approvalRequestId: task.pending_approval?.id ?? null,
        proposedAction: task.pending_approval?.proposed_action ?? null,
      });
    }

    if (items.length > 0) {
      hydrate(items, { open: true });
    }
  }, [
    hydrate,
    inReview.data,
    inReview.isFetched,
    inReview.isLoading,
    waiting.data,
    waiting.isFetched,
    waiting.isLoading,
  ]);
}
