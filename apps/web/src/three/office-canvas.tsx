import { useEffect, useMemo, useRef, useState } from "react";
import { toVisualState } from "@mokaid/shared-types";
import type { Agent } from "@/api/types";
import { env } from "@/lib/env";
import { useSceneStore } from "@/stores/scene-store";
import { OfficeScene } from "./office-scene";
import type { SceneAgent } from "./types";
import { AgentStatusBadge } from "@/components/ui/status";
import { Avatar } from "@/components/ui/avatar";
import { cn } from "@/lib/cn";

interface BubblePosition {
  x: number;
  y: number;
  visible: boolean;
}

function toSceneAgents(agents: Agent[]): SceneAgent[] {
  return agents
    .filter((a) => a.status !== "archived")
    .map((agent, index) => ({
      id: agent.id,
      name: agent.display_name,
      kind: agent.kind,
      status: agent.status,
      presenceStatus: agent.presence_status,
      visualState: toVisualState(agent.status, agent.presence_status),
      color: agent.avatar_config?.primary_color ?? "#7c5cff",
      seatIndex: agent.avatar_config?.seat_index ?? index,
      currentTaskTitle: agent.current_task_id ? "Working on task" : null,
    }));
}

/** 2D fallback when WebGL is unavailable or 3D is disabled. */
function FallbackOffice({ agents, onSelectAgent }: { agents: Agent[]; onSelectAgent: (id: string) => void }) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-4 bg-bg-deep p-6">
      <p className="text-xs text-text-muted">3D view unavailable, showing team status</p>
      <div className="flex max-w-xl flex-wrap items-center justify-center gap-3">
        {agents.map((agent) => (
          <button
            key={agent.id}
            onClick={() => onSelectAgent(agent.id)}
            className="mk-card-raised flex flex-col items-center gap-2 p-3 transition-shadow hover:shadow-glow mk-focus-ring"
          >
            <Avatar
              name={agent.display_name}
              size="md"
              isAi={agent.kind === "ai"}
              color={agent.avatar_config?.primary_color}
            />
            <span className="max-w-24 truncate text-[11px] font-medium text-text">
              {agent.display_name}
            </span>
            <AgentStatusBadge status={agent.status} />
          </button>
        ))}
      </div>
    </div>
  );
}

export function OfficeCanvas({
  agents,
  onSelectAgent,
}: {
  agents: Agent[];
  onSelectAgent: (id: string | null) => void;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const sceneRef = useRef<OfficeScene | null>(null);
  const [bubbles, setBubbles] = useState<Map<string, BubblePosition>>(new Map());
  const [webglFailed, setWebglFailed] = useState(false);

  const fps = useSceneStore((s) => s.fps);
  const setFps = useSceneStore((s) => s.setFps);

  const sceneAgents = useMemo(() => toSceneAgents(agents), [agents]);
  const disable3d = env.VITE_DISABLE_3D || webglFailed;

  // Create the scene once; never re-create on React re-renders.
  useEffect(() => {
    if (disable3d || !canvasRef.current || sceneRef.current) return;

    try {
      sceneRef.current = new OfficeScene(canvasRef.current, {
        onSelectAgent,
        onFps: setFps,
        onBubblePositions: setBubbles,
      });
    } catch (error) {
      console.warn("[3d] WebGL initialization failed, using fallback", error);
      setWebglFailed(true);
    }

    return () => {
      sceneRef.current?.dispose();
      sceneRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [disable3d]);

  // Push agent updates into the running scene.
  useEffect(() => {
    sceneRef.current?.updateAgents(sceneAgents);
  }, [sceneAgents]);

  if (disable3d) {
    return <FallbackOffice agents={agents} onSelectAgent={onSelectAgent} />;
  }

  const busyAgents = sceneAgents.filter((a) =>
    ["typing", "working", "waiting", "requesting_approval", "blocked"].includes(a.visualState),
  );

  return (
    <div className="relative h-full w-full overflow-hidden">
      <canvas ref={canvasRef} className="h-full w-full outline-none" aria-label="3D office view" />

      {/* Status bubbles overlay */}
      {busyAgents.map((agent) => {
        const position = bubbles.get(agent.id);
        if (!position?.visible) return null;

        return (
          <button
            key={agent.id}
            onClick={() => onSelectAgent(agent.id)}
            className={cn(
              "pointer-events-auto absolute z-10 -translate-x-1/2 -translate-y-full whitespace-nowrap",
              "rounded-full border border-border bg-surface-overlay/95 px-2.5 py-1 text-[10px] font-medium text-text shadow-md backdrop-blur",
              "transition-opacity hover:border-primary/50",
            )}
            style={{ left: position.x, top: position.y }}
          >
            <span
              className="mr-1.5 inline-block h-1.5 w-1.5 rounded-full"
              style={{
                backgroundColor:
                  agent.visualState === "blocked"
                    ? "#f87171"
                    : agent.visualState === "waiting" || agent.visualState === "requesting_approval"
                      ? "#fbbf24"
                      : "#34d399",
              }}
            />
            {agent.name.split(" ")[0]}
            {agent.visualState === "typing" && " · typing…"}
            {agent.visualState === "working" && " · working"}
            {agent.visualState === "waiting" && " · waiting"}
            {agent.visualState === "requesting_approval" && " · needs approval"}
            {agent.visualState === "blocked" && " · blocked"}
          </button>
        );
      })}

      {/* FPS monitor */}
      <div className="absolute bottom-3 right-3 rounded-md border border-border bg-surface-overlay/80 px-2 py-1 text-[10px] font-mono text-text-muted backdrop-blur">
        {fps} FPS
      </div>

      {/* Temporary assets notice */}
      <div className="absolute bottom-3 left-3 rounded-md border border-border bg-surface-overlay/80 px-2 py-1 text-[10px] text-text-muted backdrop-blur">
        Preview office, final 3D assets coming soon
      </div>
    </div>
  );
}
