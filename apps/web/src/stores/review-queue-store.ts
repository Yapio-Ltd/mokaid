import { create } from "zustand";

export type ReviewKind = "in_review" | "tool_approval";

export interface ReviewQueueItem {
  taskId: string;
  kind: ReviewKind;
  title: string;
  agentName?: string | null;
  /** Required for tool_approval decisions; may be filled after task detail loads. */
  approvalRequestId?: string | null;
  proposedAction?: string | null;
}

interface ReviewQueueState {
  queue: ReviewQueueItem[];
  /** When true, the review gate modal is visible. */
  modalOpen: boolean;
  enqueue: (item: ReviewQueueItem, opts?: { open?: boolean }) => void;
  /** Merge many items (hydration). Opens modal if any were added and open=true. */
  hydrate: (items: ReviewQueueItem[], opts?: { open?: boolean }) => void;
  dequeue: (taskId: string, kind?: ReviewKind) => void;
  /** Close modal but keep the queue (banner stays). */
  snooze: () => void;
  open: () => void;
  close: () => void;
  updateItem: (taskId: string, kind: ReviewKind, patch: Partial<ReviewQueueItem>) => void;
}

function itemKey(item: Pick<ReviewQueueItem, "taskId" | "kind">): string {
  return `${item.kind}:${item.taskId}`;
}

function mergeItem(existing: ReviewQueueItem, incoming: ReviewQueueItem): ReviewQueueItem {
  return {
    ...existing,
    title: incoming.title || existing.title,
    agentName: incoming.agentName ?? existing.agentName,
    approvalRequestId: incoming.approvalRequestId ?? existing.approvalRequestId,
    proposedAction: incoming.proposedAction ?? existing.proposedAction,
  };
}

export const useReviewQueueStore = create<ReviewQueueState>((set, get) => ({
  queue: [],
  modalOpen: false,

  enqueue: (item, opts) => {
    const open = opts?.open ?? true;
    const key = itemKey(item);
    const { queue } = get();
    const idx = queue.findIndex((q) => itemKey(q) === key);
    const next =
      idx >= 0
        ? queue.map((q, i) => (i === idx ? mergeItem(q, item) : q))
        : [...queue, item];
    set({
      queue: next,
      modalOpen: open ? true : get().modalOpen,
    });
  },

  hydrate: (items, opts) => {
    if (items.length === 0) return;
    const open = opts?.open ?? true;
    let queue = [...get().queue];
    for (const item of items) {
      const key = itemKey(item);
      const idx = queue.findIndex((q) => itemKey(q) === key);
      if (idx >= 0) {
        queue = queue.map((q, i) => (i === idx ? mergeItem(q, item) : q));
      } else {
        queue = [...queue, item];
      }
    }
    set({
      queue,
      modalOpen: open && queue.length > 0 ? true : get().modalOpen,
    });
  },

  dequeue: (taskId, kind) => {
    set((s) => {
      const queue = s.queue.filter((q) =>
        kind ? !(q.taskId === taskId && q.kind === kind) : q.taskId !== taskId,
      );
      return {
        queue,
        modalOpen: queue.length === 0 ? false : s.modalOpen,
      };
    });
  },

  snooze: () => set({ modalOpen: false }),
  open: () => {
    if (get().queue.length > 0) set({ modalOpen: true });
  },
  close: () => set({ modalOpen: false }),

  updateItem: (taskId, kind, patch) => {
    set((s) => ({
      queue: s.queue.map((q) =>
        q.taskId === taskId && q.kind === kind ? { ...q, ...patch } : q,
      ),
    }));
  },
}));
