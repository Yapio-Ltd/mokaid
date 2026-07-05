import { useState } from "react";
import { ChevronDown, ChevronRight, Sparkles } from "lucide-react";
import {
  useAgents,
  useCreateTask,
  useDispatchAnalyze,
  useExecuteAi,
  useProjects,
} from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/cn";

interface NewTaskModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  defaultProjectId?: string;
}

const priorityOptions = [
  { value: "low", label: "Low" },
  { value: "medium", label: "Medium" },
  { value: "high", label: "High" },
  { value: "urgent", label: "Urgent" },
];

/** First line of the brief, trimmed to a title-sized string. */
function deriveTitle(text: string): string {
  const firstLine = text.split(/\r?\n/).find((line) => line.trim()) ?? "";
  const trimmed = firstLine.trim().replace(/[.!?]+$/, "");
  return trimmed.length > 80 ? `${trimmed.slice(0, 77)}…` : trimmed;
}

export function NewTaskModal({ open, onOpenChange, defaultProjectId }: NewTaskModalProps) {
  const createTask = useCreateTask();
  const executeAi = useExecuteAi();
  const analyze = useDispatchAnalyze();
  const { data: projectsData } = useProjects();
  const { data: agentsData } = useAgents();

  const [brief, setBrief] = useState("");
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [autoAssign, setAutoAssign] = useState(true);
  const [projectId, setProjectId] = useState<string | undefined>(defaultProjectId);
  const [agentId, setAgentId] = useState<string | undefined>();
  const [priority, setPriority] = useState<string | undefined>();
  const [dueAt, setDueAt] = useState("");
  const [submitting, setSubmitting] = useState(false);

  const projects = projectsData?.data ?? [];
  const agents = (agentsData?.data ?? []).filter((a) => a.status !== "archived");

  const reset = () => {
    setBrief("");
    setShowAdvanced(false);
    setAutoAssign(true);
    setProjectId(defaultProjectId);
    setAgentId(undefined);
    setPriority(undefined);
    setDueAt("");
  };

  const handleSubmit = async () => {
    const text = brief.trim();
    if (!text || submitting) return;
    setSubmitting(true);

    try {
      let finalAgentId = agentId;
      let finalPriority = priority;
      let title = deriveTitle(text);

      // No agent picked manually: let the dispatcher route the task. Any
      // failure falls back to a plain unassigned task, never blocks creation.
      if (!finalAgentId && autoAssign) {
        try {
          const { data } = await analyze.mutateAsync({ instruction: text });
          title = data.task.title || title;
          finalPriority = finalPriority ?? data.task.priority;
          if (data.recommendation.mode === "existing_agent" && data.recommendation.agent_id) {
            finalAgentId = data.recommendation.agent_id;
          }
        } catch {
          // dispatcher unavailable — create the task without assignment
        }
      }

      const created = await createTask.mutateAsync({
        title,
        description: text,
        project_id: projectId ?? undefined,
        assigned_agent_id: finalAgentId ?? undefined,
        priority: (finalPriority ?? "medium") as never,
        due_at: dueAt ? new Date(dueAt).toISOString() : undefined,
      });

      const assignedAgent = agents.find((a) => a.id === finalAgentId);
      if (finalAgentId && assignedAgent?.kind !== "human_linked") {
        executeAi.mutate({ taskId: created.data.id });
      }

      reset();
      onOpenChange(false);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title="New Task"
      description="Just describe what you need. Everything else is optional."
      footer={
        <>
          <Button variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button size="sm" loading={submitting} disabled={!brief.trim()} onClick={handleSubmit}>
            <Sparkles size={13} />
            Create Task
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Textarea
          autoFocus
          placeholder={
            "e.g. Write the launch announcement for our new feature, friendly tone, under 200 words, mention the free trial…"
          }
          value={brief}
          onChange={(e) => setBrief(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) handleSubmit();
          }}
          className="min-h-[110px]"
        />

        {!agentId && (
          <label className="flex cursor-pointer items-center gap-2.5 rounded-md border border-primary/25 bg-primary-muted/30 px-3 py-2.5">
            <input
              type="checkbox"
              checked={autoAssign}
              onChange={(e) => setAutoAssign(e.target.checked)}
              className="h-3.5 w-3.5 accent-[var(--mk-primary-500)]"
            />
            <span className="flex items-center gap-1.5 text-xs text-text">
              <Sparkles size={13} className="text-primary-light" />
              Auto-assign to the best agent and start right away
            </span>
          </label>
        )}

        <button
          type="button"
          onClick={() => setShowAdvanced((v) => !v)}
          className="flex items-center gap-1 text-[11px] font-medium text-text-muted transition-colors hover:text-text mk-focus-ring rounded"
        >
          {showAdvanced ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
          Advanced options
        </button>

        <div className={cn("space-y-3", !showAdvanced && "hidden")}>
          <div className="grid grid-cols-2 gap-3">
            <Field label="Project">
              <Select
                value={projectId}
                onValueChange={setProjectId}
                placeholder="No project"
                options={projects.map((p) => ({ value: p.id, label: p.name }))}
              />
            </Field>
            <Field label="Assign to agent">
              <Select
                value={agentId}
                onValueChange={setAgentId}
                placeholder="Auto (recommended)"
                options={agents.map((a) => ({
                  value: a.id,
                  label: `${a.display_name}${a.kind === "ai" ? " (AI)" : a.kind === "hybrid" ? " (Hybrid)" : ""}`,
                }))}
              />
            </Field>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <Field label="Priority">
              <Select
                value={priority}
                onValueChange={setPriority}
                placeholder="Auto"
                options={priorityOptions}
              />
            </Field>
            <Field label="Due date">
              <input
                type="date"
                className="mk-input"
                value={dueAt}
                onChange={(e) => setDueAt(e.target.value)}
              />
            </Field>
          </div>
        </div>
      </div>
    </Dialog>
  );
}
