import { create } from "zustand";

export type ToastTone = "info" | "success" | "error" | "working" | "warning";

export interface ToastItem {
  id: number;
  title: string;
  description?: string;
  tone: ToastTone;
  /** When set, clicking the toast opens this task's detail panel. */
  taskId?: string;
  duration?: number;
}

let nextId = 1;

interface ToastState {
  toasts: ToastItem[];
  push: (toast: Omit<ToastItem, "id">) => void;
  dismiss: (id: number) => void;
}

export const useToastStore = create<ToastState>((set, get) => ({
  toasts: [],
  push: (toast) => {
    const id = nextId++;
    set((s) => ({ toasts: [...s.toasts.slice(-3), { ...toast, id }] }));
    window.setTimeout(() => get().dismiss(id), toast.duration ?? 6000);
  },
  dismiss: (id) => set((s) => ({ toasts: s.toasts.filter((t) => t.id !== id) })),
}));

/** Imperative toast helper usable outside React components. */
export function toast(item: Omit<ToastItem, "id">): void {
  useToastStore.getState().push(item);
}
