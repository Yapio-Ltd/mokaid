import type { AgentVisualState } from "@mokaid/shared-types";

/** Minimal agent data the 3D layer needs. Kept decoupled from API types. */
export interface SceneAgent {
  id: string;
  name: string;
  kind: string;
  status: string;
  presenceStatus: string;
  visualState: AgentVisualState;
  color: string;
  seatIndex: number;
  currentTaskTitle: string | null;
}

export interface SceneCallbacks {
  onSelectAgent: (agentId: string | null) => void;
  onFps: (fps: number) => void;
  onBubblePositions: (positions: Map<string, { x: number; y: number; visible: boolean }>) => void;
}
