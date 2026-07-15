import type { AgentVisualState } from "@mokaid/shared-types";
import type { SecondaryActivity } from "./office-navdata";

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
  /** Resolved CDN/public path for the agent's 3D avatar GLB. */
  avatarCdnPath?: string | null;
  /** Synchronized secondary activity from the backend office scheduler. */
  secondaryActivity?: SecondaryActivity;
  officePoiId?: string | null;
  officeSlotId?: string | null;
  officeActivityPhase?: string | null;
}

export interface SceneCallbacks {
  onSelectAgent: (agentId: string | null) => void;
  onFps: (fps: number) => void;
  onBubblePositions: (positions: Map<string, { x: number; y: number; visible: boolean }>) => void;
  /** Progress of the office environment GLB load (0–1). */
  onLoadProgress?: (progress: number) => void;
  /** Fired once the environment is ready (or failed). */
  onOfficeReady?: (ok: boolean) => void;
  /** Local locomotion activity when no server activity is set (e.g. walking). */
  onAgentActivity?: (agentId: string, activity: SecondaryActivity) => void;
}
