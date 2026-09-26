import { create } from "zustand";

interface FeedbackDraft {
  prompt: string;
  editing: boolean;
}

interface TaskFeedbackState {
  drafts: Record<string, FeedbackDraft | undefined>;
  setDraft: (key: string, draft: FeedbackDraft) => void;
  clearDraft: (key: string) => void;
}

/** Keep instructions when closing a task, without leaking them between tasks or workspaces. */
export const useTaskFeedbackStore = create<TaskFeedbackState>((set) => ({
  drafts: {},
  setDraft: (key, draft) => set((state) => ({ drafts: { ...state.drafts, [key]: draft } })),
  clearDraft: (key) =>
    set((state) => {
      const drafts = { ...state.drafts };
      delete drafts[key];
      return { drafts };
    }),
}));
