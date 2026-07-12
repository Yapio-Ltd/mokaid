import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type DragEvent,
  type ReactNode,
} from "react";
import { toVisualState } from "@mokaid/shared-types";
import { UploadCloud } from "lucide-react";
import type { Agent } from "@/api/types";
import { useAssets3d } from "@/api/hooks";
import { env } from "@/lib/env";
import { useSceneStore } from "@/stores/scene-store";
import { useChatStore } from "@/stores/chat-store";
import { OfficeScene } from "./office-scene";
import type { SceneAgent } from "./types";
import { AgentSceneLabel } from "./agent-scene-label";
import { applyLabelPositions } from "./label-overlay";
import { AgentStatusBadge } from "@/components/ui/status";
import { Avatar } from "@/components/ui/avatar";
import { DropDispatchModal } from "@/components/modals/drop-dispatch-modal";
import { DEFAULT_AVATAR_CDN_PATH } from "./agent-model";

interface BubblePosition {
  x: number;
  y: number;
  visible: boolean;
}

const MAX_OFFICE_SEATS = 9;

function toSceneAgents(
  agents: Agent[],
  typingIds: string[],
  assetCdnById: Map<string, string>,
): SceneAgent[] {
  const typing = new Set(typingIds);
  return agents
    .filter((a) => a.status !== "archived")
    .slice(0, MAX_OFFICE_SEATS)
    .map((agent, index) => {
      // An agent composing a chat reply visibly types at its desk, whatever
      // its task status is.
      const isTyping = typing.has(agent.id);
      const avatarCdnPath =
        agent.avatar_cdn_path ||
        (agent.avatar_asset_id && assetCdnById.get(agent.avatar_asset_id)) ||
        DEFAULT_AVATAR_CDN_PATH;
      return {
        id: agent.id,
        name: agent.display_name,
        kind: agent.kind,
        status: agent.status,
        presenceStatus: agent.presence_status,
        visualState: isTyping
          ? "typing"
          : toVisualState(agent.status, agent.presence_status, {
              has_task: Boolean(agent.current_task_id),
            }),
        color: agent.avatar_config?.primary_color ?? "#7c5cff",
        seatIndex: agent.avatar_config?.seat_index ?? index,
        currentTaskTitle: isTyping
          ? "typing a message…"
          : agent.current_task_id
            ? "Working on task"
            : null,
        avatarCdnPath,
      };
    });
}

/**
 * Drop target covering the whole office view: any file dragged from the OS
 * highlights the zone; dropping opens the smart dispatch flow.
 */
function OfficeDropzone({ children }: { children: ReactNode }) {
  const [dragActive, setDragActive] = useState(false);
  const [droppedFiles, setDroppedFiles] = useState<File[]>([]);
  const [showDispatch, setShowDispatch] = useState(false);
  // dragenter/dragleave fire on every child; a depth counter keeps the
  // highlight stable until the pointer truly leaves the zone.
  const dragDepth = useRef(0);

  const hasFiles = (e: DragEvent) => Array.from(e.dataTransfer.types).includes("Files");

  const onDragEnter = useCallback((e: DragEvent) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    dragDepth.current += 1;
    setDragActive(true);
  }, []);

  const onDragOver = useCallback((e: DragEvent) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "copy";
  }, []);

  const onDragLeave = useCallback((e: DragEvent) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    dragDepth.current = Math.max(0, dragDepth.current - 1);
    if (dragDepth.current === 0) setDragActive(false);
  }, []);

  const onDrop = useCallback((e: DragEvent) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    dragDepth.current = 0;
    setDragActive(false);
    const files = Array.from(e.dataTransfer.files);
    if (files.length > 0) {
      setDroppedFiles(files);
      setShowDispatch(true);
    }
  }, []);

  return (
    <div
      className="relative h-full w-full"
      onDragEnter={onDragEnter}
      onDragOver={onDragOver}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
    >
      {children}

      {dragActive && (
        <div className="pointer-events-none absolute inset-0 z-20 p-2">
          <div className="mk-dropzone-active flex h-full w-full flex-col items-center justify-center gap-3 rounded-xl border-2 border-dashed border-primary/70 bg-bg/70 backdrop-blur-sm">
            <span className="mk-dropzone-icon flex h-14 w-14 items-center justify-center rounded-full bg-primary-muted text-primary-light">
              <UploadCloud size={26} />
            </span>
            <div className="text-center">
              <p className="text-sm font-semibold text-text">Drop your files here</p>
              <p className="mt-0.5 text-xs text-text-muted">
                Any format. The dispatcher will route them to the right agent
              </p>
            </div>
          </div>
        </div>
      )}

      <DropDispatchModal open={showDispatch} onOpenChange={setShowDispatch} files={droppedFiles} />
    </div>
  );
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
  selectedAgentId,
  onSelectAgent,
}: {
  agents: Agent[];
  selectedAgentId?: string | null;
  onSelectAgent: (id: string | null) => void;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const sceneRef = useRef<OfficeScene | null>(null);
  const labelRefs = useRef<Map<string, HTMLButtonElement>>(new Map());
  const [webglFailed, setWebglFailed] = useState(false);

  const fps = useSceneStore((s) => s.fps);
  const setFps = useSceneStore((s) => s.setFps);

  const typingAgentIds = useChatStore((s) => s.typingAgentIds);
  const { data: characterAssets } = useAssets3d("character");
  const assetCdnById = useMemo(() => {
    const map = new Map<string, string>();
    for (const asset of characterAssets ?? []) {
      map.set(asset.id, asset.cdn_path || asset.url);
    }
    return map;
  }, [characterAssets]);
  const sceneAgents = useMemo(
    () => toSceneAgents(agents, typingAgentIds, assetCdnById),
    [agents, typingAgentIds, assetCdnById],
  );
  const disable3d = env.VITE_DISABLE_3D || webglFailed;

  const registerLabel = useCallback((agentId: string, node: HTMLButtonElement | null) => {
    if (node) labelRefs.current.set(agentId, node);
    else labelRefs.current.delete(agentId);
  }, []);

  // Create the scene once; never re-create on React re-renders.
  useEffect(() => {
    if (disable3d || !canvasRef.current || sceneRef.current) return;

    try {
      sceneRef.current = new OfficeScene(canvasRef.current, {
        onSelectAgent,
        onFps: setFps,
        onBubblePositions: (positions: Map<string, BubblePosition>) => {
          applyLabelPositions(labelRefs.current, positions);
        },
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
    return (
      <OfficeDropzone>
        <FallbackOffice agents={agents} onSelectAgent={onSelectAgent} />
      </OfficeDropzone>
    );
  }

  // Every present agent keeps its name bubble — only truly absent ones
  // (away/offline) go unlabeled.
  const labeledAgents = sceneAgents.filter(
    (a) => !["away", "offline"].includes(a.visualState),
  );

  return (
    <OfficeDropzone>
      <div className="relative h-full w-full overflow-hidden">
        <canvas ref={canvasRef} className="h-full w-full outline-none" aria-label="3D office view" />

        {/* Status bubbles overlay — positions updated imperatively each frame */}
        {labeledAgents.map((agent) => (
          <AgentSceneLabel
            key={agent.id}
            ref={(node) => registerLabel(agent.id, node)}
            agent={agent}
            selected={agent.id === selectedAgentId}
            onClick={() => onSelectAgent(agent.id)}
          />
        ))}

        {/* FPS monitor */}
        <div className="absolute bottom-3 right-3 rounded-md border border-border bg-surface-overlay/80 px-2 py-1 text-[10px] font-mono text-text-muted backdrop-blur">
          {fps} FPS
        </div>

        {/* Temporary assets notice */}
        <div className="absolute bottom-3 left-3 rounded-md border border-border bg-surface-overlay/80 px-2 py-1 text-[10px] text-text-muted backdrop-blur">
          Preview office, final 3D assets coming soon
        </div>
      </div>
    </OfficeDropzone>
  );
}
