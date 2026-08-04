import { create } from "zustand";

export interface DeliverableFile {
  /** Drive item id — bytes are fetched through the authenticated API. */
  id: string;
  name: string;
  mime_type: string | null;
}

interface DeliverableState {
  file: DeliverableFile | null;
  openDeliverable: (file: DeliverableFile) => void;
  closeDeliverable: () => void;
}

/** Immersive deliverable viewer (PDF / image / website / document) — global
 * so any surface (task panel, chat, drive) can open a file full-screen. */
export const useDeliverableStore = create<DeliverableState>((set) => ({
  file: null,
  openDeliverable: (file) => set({ file }),
  closeDeliverable: () => set({ file: null }),
}));

export function openDeliverable(file: DeliverableFile): void {
  useDeliverableStore.getState().openDeliverable(file);
}
