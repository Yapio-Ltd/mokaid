import { create } from "zustand";

/**
 * Bridge between the isolated Babylon 3D layer and React.
 * The 3D scene reads/writes here without triggering scene re-creation.
 */
interface SceneState {
  ready: boolean;
  fps: number;
  fallbackMode: boolean;
  hoveredAgentId: string | null;
  setReady: (ready: boolean) => void;
  setFps: (fps: number) => void;
  setFallbackMode: (fallback: boolean) => void;
  setHoveredAgent: (id: string | null) => void;
}

export const useSceneStore = create<SceneState>((set) => ({
  ready: false,
  fps: 0,
  fallbackMode: false,
  hoveredAgentId: null,
  setReady: (ready) => set({ ready }),
  setFps: (fps) => set({ fps }),
  setFallbackMode: (fallbackMode) => set({ fallbackMode }),
  setHoveredAgent: (hoveredAgentId) => set({ hoveredAgentId }),
}));
