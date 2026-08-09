import { create } from "zustand";
import type { ToolActivityEvent } from "@/api/types";

const MAX_EVENTS = 200;

interface ToolActivityState {
  /** Live tool-call feed per task, streamed over the workspace channel. */
  feeds: Record<string, ToolActivityEvent[]>;
  push: (taskId: string, event: ToolActivityEvent) => void;
  clear: (taskId: string) => void;
}

/**
 * Live run timeline: the AI worker streams every tool call (start/end with a
 * human description) through Phoenix (`task.tool_activity`). Events with the
 * same id update in place (running → ok/error), so the UI can show spinners
 * that resolve without refetching the task.
 */
export const useToolActivityStore = create<ToolActivityState>((set) => ({
  feeds: {},
  push: (taskId, event) =>
    set((state) => {
      const feed = state.feeds[taskId] ?? [];
      const index = feed.findIndex((e) => e.id === event.id);
      const next =
        index >= 0
          ? feed.map((e, i) => (i === index ? { ...e, ...event } : e))
          : [...feed, event].slice(-MAX_EVENTS);
      return { feeds: { ...state.feeds, [taskId]: next } };
    }),
  clear: (taskId) =>
    set((state) => {
      if (!(taskId in state.feeds)) return state;
      const { [taskId]: _removed, ...rest } = state.feeds;
      return { feeds: rest };
    }),
}));
