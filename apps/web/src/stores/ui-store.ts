import { create } from "zustand";

const FLASH_DURATION_MS = 5000;

interface UiState {
  sidebarCollapsed: boolean;
  selectedAgentId: string | null;
  selectedTaskId: string | null;
  /**
   * Task id to open after the next route change (toasts / notifications
   * that navigate away from the current page). Consumed by AppShell.
   */
  pendingTaskId: string | null;
  /** Task ids briefly highlighted after their run finished (realtime). */
  flashedTaskIds: string[];
  /** Number of currently mounted overlay/inline detail panels. */
  detailPanelCount: number;
  toggleSidebar: () => void;
  selectAgent: (id: string | null) => void;
  selectTask: (id: string | null) => void;
  /** Queue a task to open once navigation lands (e.g. toast → /tasks). */
  requestOpenTask: (id: string) => void;
  /** Apply pendingTaskId → selectedTaskId if set; return whether something was applied. */
  consumePendingTask: () => boolean;
  flashTask: (id: string) => void;
  incrementDetailPanel: () => void;
  decrementDetailPanel: () => void;
}

export const useUiStore = create<UiState>((set, get) => ({
  sidebarCollapsed: false,
  selectedAgentId: null,
  selectedTaskId: null,
  pendingTaskId: null,
  flashedTaskIds: [],
  detailPanelCount: 0,
  toggleSidebar: () => set((s) => ({ sidebarCollapsed: !s.sidebarCollapsed })),
  selectAgent: (id) => set({ selectedAgentId: id }),
  selectTask: (id) => set({ selectedTaskId: id, pendingTaskId: null }),
  requestOpenTask: (id) => set({ pendingTaskId: id }),
  consumePendingTask: () => {
    const pending = get().pendingTaskId;
    if (!pending) return false;
    set({ selectedTaskId: pending, pendingTaskId: null });
    return true;
  },
  flashTask: (id) => {
    set((s) => ({
      flashedTaskIds: s.flashedTaskIds.includes(id)
        ? s.flashedTaskIds
        : [...s.flashedTaskIds, id],
    }));
    setTimeout(() => {
      set((s) => ({ flashedTaskIds: s.flashedTaskIds.filter((t) => t !== id) }));
    }, FLASH_DURATION_MS);
  },
  incrementDetailPanel: () => set((s) => ({ detailPanelCount: s.detailPanelCount + 1 })),
  decrementDetailPanel: () => set((s) => ({ detailPanelCount: Math.max(0, s.detailPanelCount - 1) })),
}));
