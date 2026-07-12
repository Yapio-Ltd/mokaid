import { create } from "zustand";

/** Longest an agent can appear "typing" in a task thread without a reply. */
const TYPING_TIMEOUT_MS = 30_000;

interface TaskTypingState {
  /** Task ids whose assigned agent is composing a reply right now. */
  typingTaskIds: string[];
  setTyping: (taskId: string) => void;
  clearTyping: (taskId: string) => void;
}

const timers = new Map<string, ReturnType<typeof setTimeout>>();

/**
 * Typing indicator for task threads: set the instant Phoenix broadcasts
 * `task.agent_typing` (before the LLM round-trip), cleared when the agent's
 * comment lands or after a safety timeout.
 */
export const useTaskTypingStore = create<TaskTypingState>((set) => ({
  typingTaskIds: [],

  setTyping: (taskId) => {
    clearTimeout(timers.get(taskId));
    timers.set(
      taskId,
      setTimeout(() => useTaskTypingStore.getState().clearTyping(taskId), TYPING_TIMEOUT_MS),
    );
    set((s) => ({
      typingTaskIds: s.typingTaskIds.includes(taskId)
        ? s.typingTaskIds
        : [...s.typingTaskIds, taskId],
    }));
  },

  clearTyping: (taskId) => {
    clearTimeout(timers.get(taskId));
    timers.delete(taskId);
    set((s) => ({ typingTaskIds: s.typingTaskIds.filter((id) => id !== taskId) }));
  },
}));
