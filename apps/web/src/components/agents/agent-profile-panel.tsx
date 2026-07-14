import { useCallback, useEffect, useRef, useState } from "react";
import * as Tabs from "@radix-ui/react-tabs";
import {
  Check,
  FileUp,
  Link2,
  Pencil,
  Sparkles,
  Trash2,
  Upload,
  X,
} from "lucide-react";
import type { Agent } from "@/api/types";
import {
  useAgentProgression,
  useTasks,
  useUpdateAgent,
  useUploadAgentFiles,
  useDeleteAgent,
} from "@/api/hooks";
import { DetailPanel } from "@/components/ui/detail-panel";
import { AgentAvatar } from "@/components/agents/agent-avatar";
import { AgentStatusBadge, TaskStatusBadge } from "@/components/ui/status";
import { ProgressBar } from "@/components/ui/progress-bar";
import { Badge } from "@/components/ui/badge";
import { AgentMcpMatrix } from "@/components/mcp/agent-mcp-matrix";
import { formatRelative } from "@/lib/format";
import { cn } from "@/lib/cn";
import { toast } from "@/stores/toast-store";
import { useUiStore } from "@/stores/ui-store";

const tabClass =
  "flex-1 px-2 py-2.5 text-xs font-medium text-text-muted transition-colors rounded-md hover:text-text hover:bg-surface-hover data-[state=active]:bg-primary-muted data-[state=active]:text-primary-light";

function EditableName({
  value,
  onSave,
  saving,
}: {
  value: string;
  onSave: (name: string) => void;
  saving?: boolean;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(value);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!editing) setDraft(value);
  }, [value, editing]);

  const startEditing = () => {
    setDraft(value);
    setEditing(true);
    setTimeout(() => inputRef.current?.focus(), 0);
  };

  const save = () => {
    const trimmed = draft.trim();
    if (!trimmed) {
      setDraft(value);
      setEditing(false);
      return;
    }
    if (trimmed !== value) onSave(trimmed);
    setEditing(false);
  };

  const cancel = () => {
    setDraft(value);
    setEditing(false);
  };

  if (editing) {
    return (
      <div className="flex w-full max-w-[260px] items-center gap-1.5">
        <input
          ref={inputRef}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={save}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              (e.target as HTMLInputElement).blur();
            }
            if (e.key === "Escape") cancel();
          }}
          disabled={saving}
          aria-label="Agent name"
          className="min-w-0 flex-1 rounded-md border border-primary/50 bg-surface-raised px-2 py-1 text-center text-sm font-bold text-text outline-none focus:border-primary"
        />
        <button
          type="button"
          onMouseDown={(e) => e.preventDefault()}
          onClick={save}
          className="rounded p-1 text-success hover:bg-surface-hover"
          aria-label="Save name"
        >
          <Check size={14} />
        </button>
        <button
          type="button"
          onMouseDown={(e) => e.preventDefault()}
          onClick={cancel}
          className="rounded p-1 text-text-muted hover:bg-surface-hover"
          aria-label="Cancel rename"
        >
          <X size={14} />
        </button>
      </div>
    );
  }

  return (
    <button
      type="button"
      onClick={startEditing}
      title="Rename agent"
      aria-label={`Rename ${value}`}
      className="group flex items-center gap-1.5 rounded-md px-1.5 py-0.5 transition-colors hover:bg-surface-hover"
    >
      <span className="text-base font-bold text-text">{value}</span>
      <Pencil
        size={12}
        className="shrink-0 text-text-muted transition-colors group-hover:text-primary-light"
      />
    </button>
  );
}

function FileDropZone({
  agentId,
  agentName,
}: {
  agentId: string;
  agentName: string;
}) {
  const [dragActive, setDragActive] = useState(false);
  const [uploadedFiles, setUploadedFiles] = useState<string[]>([]);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const uploadMutation = useUploadAgentFiles();

  const handleFiles = useCallback(
    (files: FileList | File[]) => {
      const fileArray = Array.from(files);
      if (fileArray.length === 0) return;

      uploadMutation.mutate(
        { agentId, files: fileArray },
        {
          onSuccess: () => {
            setUploadedFiles((prev) => [
              ...prev,
              ...fileArray.map((f) => f.name),
            ]);
          },
        },
      );
    },
    [agentId, uploadMutation],
  );

  return (
    <div className="space-y-3">
      <p className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
        Feed Data to {agentName.split(" ")[0]}
      </p>

      <div
        onDragOver={(e) => {
          e.preventDefault();
          setDragActive(true);
        }}
        onDragLeave={() => setDragActive(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDragActive(false);
          handleFiles(e.dataTransfer.files);
        }}
        onClick={() => fileInputRef.current?.click()}
        className={cn(
          "flex cursor-pointer flex-col items-center gap-2 rounded-xl border-2 border-dashed p-5 transition-all",
          dragActive
            ? "border-primary bg-primary-muted/30"
            : "border-border/60 hover:border-primary/40 hover:bg-surface-hover/50",
        )}
      >
        <div
          className={cn(
            "flex h-10 w-10 items-center justify-center rounded-full transition-colors",
            dragActive ? "bg-primary/20 text-primary-light" : "bg-surface-raised text-text-muted",
          )}
        >
          <Upload size={18} />
        </div>
        <div className="text-center">
          <p className="text-xs font-medium text-text">
            Drop files or click to browse
          </p>
          <p className="mt-0.5 text-[11px] text-text-muted">
            PDF, DOC, CSV, TXT, JSON...
          </p>
        </div>
        <input
          ref={fileInputRef}
          type="file"
          multiple
          className="hidden"
          onChange={(e) => {
            if (e.target.files) handleFiles(e.target.files);
            e.target.value = "";
          }}
        />
      </div>

      {uploadMutation.isPending && (
        <div className="flex items-center gap-2 rounded-lg bg-primary-muted/30 px-3 py-2">
          <div className="h-3 w-3 animate-spin rounded-full border-2 border-primary border-t-transparent" />
          <span className="text-[11px] text-primary-light">Uploading...</span>
        </div>
      )}

      {uploadedFiles.length > 0 && (
        <div className="space-y-1.5">
          {uploadedFiles.map((name, i) => (
            <div
              key={i}
              className="flex items-center gap-2 rounded-lg bg-success/10 px-3 py-2"
            >
              <FileUp size={12} className="text-success" />
              <span className="min-w-0 flex-1 truncate text-[11px] text-text">
                {name}
              </span>
              <Check size={12} className="text-success" />
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

/** "Level" tab: XP bar, mission count and the agent's freshest memories —
 *  the employee's career sheet, video-game style. */
function ProgressionTab({ agent }: { agent: Agent }) {
  const { data } = useAgentProgression(agent.id);
  const progression = data?.data;

  const level = progression?.level ?? agent.level;
  const xp = progression?.xp ?? agent.xp;
  const xpForNext = progression?.xp_for_next_level ?? agent.xp_for_next_level;
  const missions = progression?.missions_completed ?? agent.missions_completed;
  const pct = xpForNext > 0 ? Math.round((xp / xpForNext) * 100) : 0;

  return (
    <div className="space-y-5">
      <div className="flex items-center gap-4 rounded-xl bg-surface-raised/60 p-4">
        <AgentAvatar agent={{ ...agent, level, xp, xp_for_next_level: xpForNext }} size="lg" />
        <div className="min-w-0 flex-1">
          <p className="text-sm font-bold text-text">Level {level}</p>
          <div className="mt-1.5">
            <ProgressBar value={pct} />
          </div>
          <p className="mt-1 text-[11px] text-text-muted">
            {xp} / {xpForNext} XP to level {level + 1}
          </p>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="rounded-xl bg-surface-raised/60 p-4 text-center">
          <p className="text-xl font-bold text-text">{missions}</p>
          <p className="mt-0.5 text-[11px] text-text-muted">Missions completed</p>
        </div>
        <div className="rounded-xl bg-surface-raised/60 p-4 text-center">
          <p className="text-xl font-bold capitalize text-text">
            {progression?.specialty ?? "—"}
          </p>
          <p className="mt-0.5 text-[11px] text-text-muted">Specialty</p>
        </div>
      </div>

      {progression && progression.recent_memories.length > 0 && (
        <div>
          <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
            Recent mission memories
          </p>
          <div className="space-y-1.5">
            {progression.recent_memories.map((memory) => (
              <div
                key={memory.id}
                className="flex items-center gap-2 rounded-lg bg-surface-raised/40 px-3 py-2"
              >
                <Sparkles size={11} className="shrink-0 text-primary-light" />
                <span className="min-w-0 flex-1 truncate text-[11px] text-text">
                  {memory.title}
                </span>
                <span className="shrink-0 text-[10px] text-text-muted">
                  {formatRelative(memory.inserted_at)}
                </span>
              </div>
            ))}
          </div>
          <p className="mt-2 text-[10px] leading-relaxed text-text-muted">
            Every mission enriches this agent's vectorized knowledge — it gets
            genuinely better at what you ask it most.
          </p>
        </div>
      )}
    </div>
  );
}

function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between py-1.5">
      <span className="text-[11px] text-text-muted">{label}</span>
      <span className="text-xs font-medium text-text">{value}</span>
    </div>
  );
}

export function AgentProfilePanel({
  agent,
  onClose,
  overlay,
}: {
  agent: Agent | null;
  onClose: () => void;
  overlay?: boolean;
}) {
  const { data: tasksData } = useTasks(agent ? { agent_id: agent.id } : {});
  const updateAgent = useUpdateAgent();
  const deleteAgent = useDeleteAgent();
  const selectTask = useUiStore((s) => s.selectTask);
  const [nameDraft, setNameDraft] = useState(agent?.display_name ?? "");
  const agentTasks = agent
    ? (tasksData?.data ?? []).filter((t) => t.assigned_agent_id === agent.id)
    : [];
  const currentTask =
    agentTasks.find((t) => t.id === agent?.current_task_id) ??
    agentTasks.find((t) => t.status === "in_progress");

  useEffect(() => {
    setNameDraft(agent?.display_name ?? "");
  }, [agent?.id, agent?.display_name]);

  const handleRename = useCallback(
    (name: string) => {
      if (!agent) return;
      updateAgent.mutate(
        { id: agent.id, display_name: name },
        {
          onError: () => {
            setNameDraft(agent.display_name);
            toast({
              tone: "error",
              title: "Could not rename agent",
              description: "Check your permissions and try again.",
            });
          },
        },
      );
    },
    [agent, updateAgent],
  );

  const saveNameDraft = useCallback(() => {
    if (!agent) return;
    const trimmed = nameDraft.trim();
    if (!trimmed) {
      setNameDraft(agent.display_name);
      return;
    }
    if (trimmed !== agent.display_name) handleRename(trimmed);
  }, [agent, handleRename, nameDraft]);

  const handleDelete = useCallback(() => {
    if (!agent) return;
    if (!window.confirm(`Delete agent "${agent.display_name}"? This cannot be undone.`)) return;
    deleteAgent.mutate(agent.id, { onSuccess: onClose });
  }, [agent, deleteAgent, onClose]);

  return (
    <DetailPanel open={agent != null} onClose={onClose} title="Agent Profile" overlay={overlay}>
      {agent && (
        <div className="flex flex-col gap-0">
          {/* Header */}
          <div className="flex flex-col items-center gap-3 px-6 pb-5 pt-4">
            <AgentAvatar agent={agent} size="xl" showBadge={agent.kind === "ai"} />

            <div className="flex flex-col items-center gap-1">
              <EditableName
                value={agent.display_name}
                onSave={handleRename}
                saving={updateAgent.isPending}
              />
              <p className="text-xs text-text-muted">{agent.role_title ?? "Agent"}</p>
            </div>

            <AgentStatusBadge status={agent.status} />

            <div className="flex flex-wrap items-center justify-center gap-2">
              {agent.kind === "ai" ? (
                <Badge tone="primary">
                  <Sparkles size={10} /> AI Agent
                </Badge>
              ) : (
                <Badge tone="info">
                  <Link2 size={10} /> {agent.linked_user_name ?? "Human-linked"}
                </Badge>
              )}
              {agent.capabilities?.learning?.specialty ? (
                <Badge tone="success">
                  <Sparkles size={10} /> {agent.capabilities.learning.specialty}
                </Badge>
              ) : agent.capabilities?.learning?.missions_total != null &&
                agent.capabilities.learning.missions_total > 0 ? (
                <Badge tone="warning">
                  <Sparkles size={10} /> Learning ({agent.capabilities.learning.missions_total}{" "}
                  {agent.capabilities.learning.missions_total === 1 ? "mission" : "missions"})
                </Badge>
              ) : null}
            </div>

            {agent.performance_score != null && (
              <div className="w-full rounded-lg bg-surface-raised/50 p-3">
                <div className="mb-1.5 flex justify-between text-[11px]">
                  <span className="text-text-muted">Performance</span>
                  <span className="font-bold text-text">{agent.performance_score}%</span>
                </div>
                <ProgressBar value={agent.performance_score} tone="success" />
              </div>
            )}
          </div>

          {/* Tabs */}
          <Tabs.Root defaultValue="overview">
            <Tabs.List className="mx-4 mb-1 flex gap-1 rounded-lg bg-surface-raised/50 p-1">
              <Tabs.Trigger value="overview" className={tabClass}>
                Overview
              </Tabs.Trigger>
              <Tabs.Trigger value="data" className={tabClass}>
                Data
              </Tabs.Trigger>
              <Tabs.Trigger value="tasks" className={tabClass}>
                Tasks
              </Tabs.Trigger>
              <Tabs.Trigger value="tools" className={tabClass}>
                Tools
              </Tabs.Trigger>
              {agent.kind === "ai" && (
                <Tabs.Trigger value="progression" className={tabClass}>
                  Level
                </Tabs.Trigger>
              )}
            </Tabs.List>

            <Tabs.Content value="overview" className="space-y-5 px-5 py-4">
              <label className="block space-y-1.5">
                <span className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                  Name
                </span>
                <input
                  value={nameDraft}
                  onChange={(e) => setNameDraft(e.target.value)}
                  onBlur={saveNameDraft}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") (e.target as HTMLInputElement).blur();
                  }}
                  disabled={updateAgent.isPending}
                  placeholder="Agent name"
                  className="mk-input h-9"
                  aria-label="Agent name"
                />
              </label>

              {currentTask && (
                <div>
                  <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                    Current Task
                  </p>
                  <button
                    type="button"
                    onClick={() => selectTask(currentTask.id)}
                    className="w-full space-y-2.5 rounded-xl bg-surface-raised/60 p-4 text-left transition-colors hover:bg-surface-hover mk-focus-ring"
                  >
                    <p className="text-xs font-semibold text-text">{currentTask.title}</p>
                    <div className="flex items-center justify-between">
                      <TaskStatusBadge status={currentTask.status} />
                      <span className="text-[11px] font-medium text-text-muted">
                        {currentTask.progress_percent}%
                      </span>
                    </div>
                    <ProgressBar value={currentTask.progress_percent} />
                  </button>
                </div>
              )}

              <div className="grid grid-cols-2 gap-3">
                <div className="rounded-xl bg-surface-raised/60 p-4 text-center">
                  <p className="text-xl font-bold text-text">
                    {agentTasks.filter((t) => t.status === "in_progress").length}
                  </p>
                  <p className="mt-0.5 text-[11px] text-text-muted">In progress</p>
                </div>
                <div className="rounded-xl bg-surface-raised/60 p-4 text-center">
                  <p className="text-xl font-bold text-text">
                    {agentTasks.filter((t) => t.status === "completed").length}
                  </p>
                  <p className="mt-0.5 text-[11px] text-text-muted">Completed</p>
                </div>
              </div>

              <div className="rounded-xl bg-surface-raised/40 px-4 py-2">
                <InfoRow label="Department" value={agent.department ?? "None"} />
                <InfoRow label="Last active" value={formatRelative(agent.last_active_at)} />
                <InfoRow label="AI enabled" value={agent.ai_enabled ? "Yes" : "No"} />
              </div>

              {/* Learning progress */}
              {agent.capabilities?.learning && agent.capabilities.learning.missions_total > 0 && (
                <div>
                  <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                    Learning
                  </p>
                  <div className="space-y-2 rounded-xl bg-surface-raised/40 p-4">
                    {agent.capabilities.learning.specialty ? (
                      <div className="flex items-center gap-2">
                        <Sparkles size={12} className="shrink-0 text-success" />
                        <span className="text-xs text-text">
                          Specialised in{" "}
                          <span className="font-semibold capitalize">
                            {agent.capabilities.learning.specialty}
                          </span>
                        </span>
                      </div>
                    ) : (
                      <div className="flex items-center gap-2">
                        <Sparkles size={12} className="shrink-0 text-warning" />
                        <span className="text-xs text-text-muted">Still generalising…</span>
                      </div>
                    )}
                    <p className="text-[11px] text-text-muted">
                      {agent.capabilities.learning.missions_total} mission
                      {agent.capabilities.learning.missions_total > 1 ? "s" : ""} completed
                    </p>
                    {Object.keys(agent.capabilities.learning.domain_counts).length > 0 && (
                      <div className="flex flex-wrap gap-1.5 pt-1">
                        {Object.entries(agent.capabilities.learning.domain_counts)
                          .sort(([, a], [, b]) => b - a)
                          .map(([domain, count]) => (
                            <span
                              key={domain}
                              className="rounded-full bg-primary-muted px-2 py-0.5 text-[10px] font-medium capitalize text-primary-light"
                            >
                              {domain} ×{count}
                            </span>
                          ))}
                      </div>
                    )}
                  </div>
                </div>
              )}

              {/* Skills */}
              {agent.skills.length > 0 && (
                <div>
                  <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                    Skills
                  </p>
                  <div className="space-y-2.5 rounded-xl bg-surface-raised/40 p-4">
                    {agent.skills.map((skill) => (
                      <div key={skill.name}>
                        <div className="mb-1 flex justify-between text-[11px]">
                          <span className="font-medium text-text">{skill.name}</span>
                          <span className="text-text-muted">{skill.level}%</span>
                        </div>
                        <ProgressBar value={skill.level ?? 0} />
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </Tabs.Content>

            <Tabs.Content value="data" className="space-y-5 px-5 py-4">
              <FileDropZone agentId={agent.id} agentName={agent.display_name} />
            </Tabs.Content>

            <Tabs.Content value="tasks" className="space-y-2 px-5 py-4">
              {agentTasks.length ? (
                agentTasks.slice(0, 8).map((task) => (
                  <button
                    key={task.id}
                    type="button"
                    onClick={() => selectTask(task.id)}
                    className="flex w-full items-center justify-between gap-2 rounded-xl bg-surface-raised/60 p-3.5 text-left transition-colors hover:bg-surface-hover mk-focus-ring"
                  >
                    <p className="min-w-0 flex-1 truncate text-xs font-medium text-text">
                      {task.title}
                    </p>
                    <TaskStatusBadge status={task.status} />
                  </button>
                ))
              ) : (
                <div className="flex flex-col items-center gap-2 py-8 text-center">
                  <p className="text-xs text-text-muted">No tasks assigned.</p>
                </div>
              )}
            </Tabs.Content>

            <Tabs.Content value="tools" className="px-5 py-4">
              <AgentMcpMatrix agentId={agent.id} />
            </Tabs.Content>

            {agent.kind === "ai" && (
              <Tabs.Content value="progression" className="px-5 py-4">
                <ProgressionTab agent={agent} />
              </Tabs.Content>
            )}
          </Tabs.Root>

          {/* Delete action */}
          <div className="mt-auto px-5 pb-5 pt-3">
            <button
              onClick={handleDelete}
              className="flex w-full items-center justify-center gap-2 rounded-xl border border-red-500/20 py-2.5 text-xs font-medium text-red-400 transition-colors hover:bg-red-500/10"
            >
              <Trash2 size={13} />
              Delete Agent
            </button>
          </div>
        </div>
      )}
    </DetailPanel>
  );
}
