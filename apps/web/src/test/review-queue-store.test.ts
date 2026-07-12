import { beforeEach, describe, expect, it } from "vitest";
import { useReviewQueueStore } from "@/stores/review-queue-store";

describe("useReviewQueueStore", () => {
  beforeEach(() => {
    useReviewQueueStore.setState({ queue: [], modalOpen: false });
  });

  it("enqueues without duplicates and opens the modal", () => {
    const store = useReviewQueueStore.getState();
    store.enqueue({ taskId: "t1", kind: "in_review", title: "A" });
    store.enqueue({ taskId: "t1", kind: "in_review", title: "A updated", agentName: "Sam" });
    store.enqueue({ taskId: "t2", kind: "tool_approval", title: "B" });

    const { queue, modalOpen } = useReviewQueueStore.getState();
    expect(modalOpen).toBe(true);
    expect(queue).toHaveLength(2);
    expect(queue[0]).toMatchObject({
      taskId: "t1",
      title: "A updated",
      agentName: "Sam",
    });
  });

  it("snoozes without clearing the queue", () => {
    const store = useReviewQueueStore.getState();
    store.enqueue({ taskId: "t1", kind: "in_review", title: "A" });
    store.snooze();
    expect(useReviewQueueStore.getState().modalOpen).toBe(false);
    expect(useReviewQueueStore.getState().queue).toHaveLength(1);
    store.open();
    expect(useReviewQueueStore.getState().modalOpen).toBe(true);
  });

  it("dequeues and closes when empty", () => {
    const store = useReviewQueueStore.getState();
    store.enqueue({ taskId: "t1", kind: "in_review", title: "A" });
    store.dequeue("t1", "in_review");
    expect(useReviewQueueStore.getState().queue).toHaveLength(0);
    expect(useReviewQueueStore.getState().modalOpen).toBe(false);
  });
});
