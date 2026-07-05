import { useState } from "react";
import { Sparkles } from "lucide-react";
import { useAgents, useCreateTask, useExecuteAi, useProjects } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";

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

export function NewTaskModal({ open, onOpenChange, defaultProjectId }: NewTaskModalProps) {
  const createTask = useCreateTask();
  const executeAi = useExecuteAi();
  const { data: projectsData } = useProjects();
  const { data: agentsData } = useAgents();

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [projectId, setProjectId] = useState<string | undefined>(defaultProjectId);
  const [agentId, setAgentId] = useState<string | undefined>();
  const [priority, setPriority] = useState("medium");
  const [dueAt, setDueAt] = useState("");
  const [startNow, setStartNow] = useState(true);

  const projects = projectsData?.data ?? [];
  const agents = (agentsData?.data ?? []).filter((a) => a.status !== "archived");

  const reset = () => {
    setTitle("");
    setDescription("");
    setProjectId(defaultProjectId);
    setAgentId(undefined);
    setPriority("medium");
    setDueAt("");
    setStartNow(true);
  };

  const handleSubmit = async () => {
    if (!title.trim()) return;
    const created = await createTask.mutateAsync({
      title: title.trim(),
      description: description.trim() || undefined,
      project_id: projectId ?? undefined,
      assigned_agent_id: agentId ?? undefined,
      priority: priority as never,
      due_at: dueAt ? new Date(dueAt).toISOString() : undefined,
    });
    const selectedAgent = agents.find((a) => a.id === agentId);
    if (startNow && agentId && selectedAgent?.kind !== "human_linked") {
      executeAi.mutate({ taskId: created.data.id });
    }
    reset();
    onOpenChange(false);
  };

  const assignedAgent = agents.find((a) => a.id === agentId);
  const canRunAi = assignedAgent != null && assignedAgent.kind !== "human_linked";

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title="New Task"
      description="Describe the task in natural language — your agent will figure out the rest."
      footer={
        <>
          <Button variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            size="sm"
            loading={createTask.isPending}
            disabled={!title.trim()}
            onClick={handleSubmit}
          >
            Create Task
          </Button>
        </>
      }
    >
      <div className="space-y-4">
        <Field label="Title" required>
          <input
            className="mk-input"
            placeholder="e.g. Write the launch announcement"
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            autoFocus
          />
        </Field>
        <Field
          label="Instructions"
          hint="Explain what you need as if you were briefing a colleague."
        >
          <Textarea
            placeholder="e.g. Draft a friendly launch announcement for our new feature, keep it under 200 words, mention the free trial…"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
        </Field>
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
              placeholder="Unassigned"
              options={agents.map((a) => ({
                value: a.id,
                label: `${a.display_name}${a.kind === "ai" ? " (AI)" : a.kind === "hybrid" ? " (Hybrid)" : ""}`,
              }))}
            />
          </Field>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Priority">
            <Select value={priority} onValueChange={setPriority} options={priorityOptions} />
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
        {canRunAi && (
          <label className="flex cursor-pointer items-center gap-2.5 rounded-md border border-primary/25 bg-primary-muted/30 px-3 py-2.5">
            <input
              type="checkbox"
              checked={startNow}
              onChange={(e) => setStartNow(e.target.checked)}
              className="h-3.5 w-3.5 accent-[var(--mk-primary-500)]"
            />
            <span className="flex items-center gap-1.5 text-xs text-text">
              <Sparkles size={13} className="text-primary-light" />
              Ask {assignedAgent?.display_name} to start right away
            </span>
          </label>
        )}
      </div>
    </Dialog>
  );
}
