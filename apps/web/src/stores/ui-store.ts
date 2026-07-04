import { create } from "zustand";

interface UiState {
  sidebarCollapsed: boolean;
  selectedAgentId: string | null;
  selectedTaskId: string | null;
  toggleSidebar: () => void;
  selectAgent: (id: string | null) => void;
  selectTask: (id: string | null) => void;
}

export const useUiStore = create<UiState>((set) => ({
  sidebarCollapsed: false,
  selectedAgentId: null,
  selectedTaskId: null,
  toggleSidebar: () => set((s) => ({ sidebarCollapsed: !s.sidebarCollapsed })),
  selectAgent: (id) => set({ selectedAgentId: id }),
  selectTask: (id) => set({ selectedTaskId: id }),
}));
