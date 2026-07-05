import { create } from "zustand";
import { persist } from "zustand/middleware";

interface OnboardingState {
  /** Workspaces whose welcome wizard was completed or skipped. */
  wizardDone: Record<string, boolean>;
  /** Workspaces whose coachmark tour was completed or dismissed. */
  tourDone: Record<string, boolean>;
  tourActive: boolean;
  tourStep: number;
  markWizardDone: (workspaceId: string) => void;
  startTour: () => void;
  nextTourStep: () => void;
  prevTourStep: () => void;
  endTour: (workspaceId: string | null) => void;
  resetTour: (workspaceId: string) => void;
}

export const useOnboardingStore = create<OnboardingState>()(
  persist(
    (set) => ({
      wizardDone: {},
      tourDone: {},
      tourActive: false,
      tourStep: 0,
      markWizardDone: (workspaceId) =>
        set((s) => ({ wizardDone: { ...s.wizardDone, [workspaceId]: true } })),
      startTour: () => set({ tourActive: true, tourStep: 0 }),
      nextTourStep: () => set((s) => ({ tourStep: s.tourStep + 1 })),
      prevTourStep: () => set((s) => ({ tourStep: Math.max(0, s.tourStep - 1) })),
      endTour: (workspaceId) =>
        set((s) => ({
          tourActive: false,
          tourStep: 0,
          tourDone: workspaceId ? { ...s.tourDone, [workspaceId]: true } : s.tourDone,
        })),
      resetTour: (workspaceId) =>
        set((s) => ({
          tourDone: { ...s.tourDone, [workspaceId]: false },
          tourActive: true,
          tourStep: 0,
        })),
    }),
    {
      name: "mokaid-onboarding",
      partialize: (s) => ({ wizardDone: s.wizardDone, tourDone: s.tourDone }),
    },
  ),
);
