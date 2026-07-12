import { create } from "zustand";

export interface MissionPlanStep {
  content: string;
  status: "pending" | "in_progress" | "completed" | string;
}

interface MissionPlanState {
  /** Live deep-agent plan per task, streamed over the workspace channel. */
  plans: Record<string, MissionPlanStep[]>;
  setPlan: (taskId: string, steps: MissionPlanStep[]) => void;
  clearPlan: (taskId: string) => void;
}

/**
 * Live mission checklists: the AI worker streams every `write_todos` update
 * through Phoenix (`task.plan_updated`), and the task panel renders it in
 * real time — no refetch round-trip per todo tick.
 */
export const useMissionPlanStore = create<MissionPlanState>((set) => ({
  plans: {},
  setPlan: (taskId, steps) =>
    set((state) => ({ plans: { ...state.plans, [taskId]: steps } })),
  clearPlan: (taskId) =>
    set((state) => {
      if (!(taskId in state.plans)) return state;
      const { [taskId]: _removed, ...rest } = state.plans;
      return { plans: rest };
    }),
}));
