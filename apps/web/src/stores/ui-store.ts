import { create } from "zustand";

const FLASH_DURATION_MS = 5000;

interface UiState {
  sidebarCollapsed: boolean;
  selectedAgentId: string | null;
  selectedTaskId: string | null;
  /** Task ids briefly highlighted after their run finished (realtime). */
  flashedTaskIds: string[];
  /** Number of currently mounted overlay/inline detail panels. */
  detailPanelCount: number;
  toggleSidebar: () => void;
  selectAgent: (id: string | null) => void;
  selectTask: (id: string | null) => void;
  flashTask: (id: string) => void;
  incrementDetailPanel: () => void;
  decrementDetailPanel: () => void;
}

export const useUiStore = create<UiState>((set) => ({
  sidebarCollapsed: false,
  selectedAgentId: null,
  selectedTaskId: null,
  flashedTaskIds: [],
  detailPanelCount: 0,
  toggleSidebar: () => set((s) => ({ sidebarCollapsed: !s.sidebarCollapsed })),
  selectAgent: (id) => set({ selectedAgentId: id }),
  selectTask: (id) => set({ selectedTaskId: id }),
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
