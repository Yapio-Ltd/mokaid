import { forwardRef } from "react";
import { cn } from "@/lib/cn";
import type { SceneAgent } from "./types";

const stateText: Partial<Record<SceneAgent["visualState"], string>> = {
  typing: "typing…",
  working: "working",
  waiting: "waiting for you",
  idle: "available",
  walking: "available",
  requesting_approval: "needs approval",
  blocked: "blocked",
};

const stateColor: Partial<Record<SceneAgent["visualState"], string>> = {
  typing: "var(--mk-success)",
  working: "var(--mk-warning)",
  waiting: "var(--mk-warning)",
  idle: "var(--mk-info)",
  walking: "var(--mk-info)",
  requesting_approval: "var(--mk-warning)",
  blocked: "var(--mk-danger)",
};

/**
 * Status bubble anchored above an agent in the 3D office. Positions are updated
 * imperatively from the Babylon render loop — no position transitions here.
 */
export const AgentSceneLabel = forwardRef<
  HTMLButtonElement,
  {
    agent: SceneAgent;
    selected: boolean;
    onClick: () => void;
  }
>(function AgentSceneLabel({ agent, selected, onClick }, ref) {
  const dotColor = stateColor[agent.visualState] ?? "var(--mk-success)";

  return (
    <button
      ref={ref}
      type="button"
      onClick={onClick}
      className={cn(
        "pointer-events-auto absolute z-10 hidden -translate-x-1/2 -translate-y-full whitespace-nowrap will-change-[left,top]",
        "flex items-center gap-2 rounded-lg border bg-surface-overlay/90 py-1.5 pl-2 pr-2.5 backdrop-blur-md",
        "shadow-md transition-[border-color,box-shadow] duration-150 hover:border-primary/40",
        selected ? "border-primary/40 shadow-glow" : "border-border-strong",
      )}
    >
      {/* Status dot, pulses while the agent is typing or working */}
      <span className="relative flex h-2 w-2 shrink-0">
        {(agent.visualState === "typing" || agent.visualState === "working") && (
          <span
            className="absolute inline-flex h-full w-full animate-ping rounded-full opacity-60"
            style={{ backgroundColor: dotColor }}
          />
        )}
        <span
          className="relative inline-flex h-2 w-2 rounded-full"
          style={{ backgroundColor: dotColor }}
        />
      </span>

      <span className="flex flex-col items-start leading-none">
        <span className="text-[10px] font-semibold text-text">{agent.name.split(" ")[0]}</span>
        <span className="mt-0.5 text-[9px] font-medium text-text-muted">
          {stateText[agent.visualState] ?? agent.visualState}
        </span>
      </span>

      {/* Accent bar tinted with the agent's avatar color */}
      <span
        aria-hidden
        className="absolute inset-y-1.5 left-0 w-[2px] rounded-full opacity-80"
        style={{ backgroundColor: agent.color }}
      />

      {/* Tail pointing down at the agent */}
      <span
        aria-hidden
        className={cn(
          "absolute left-1/2 top-full h-2 w-2 -translate-x-1/2 -translate-y-1/2 rotate-45",
          "border-b border-r bg-surface-overlay/90",
          selected ? "border-primary/40" : "border-border-strong",
        )}
      />
    </button>
  );
});
