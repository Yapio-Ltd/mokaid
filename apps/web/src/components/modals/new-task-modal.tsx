import { useRef, useState } from "react";
import { ChevronDown, ChevronRight, Paperclip, Sparkles, Upload, X } from "lucide-react";
import {
  useAgents,
  useAttachTaskFile,
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
import { toast } from "@/stores/toast-store";

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

function formatSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function NewTaskModal({ open, onOpenChange, defaultProjectId }: NewTaskModalProps) {
  const createTask = useCreateTask();
  const attachFile = useAttachTaskFile();
  const executeAi = useExecuteAi();
  const analyze = useDispatchAnalyze();
  const { data: projectsData } = useProjects();
  const { data: agentsData } = useAgents();

  const [brief, setBrief] = useState("");
  const [files, setFiles] = useState<File[]>([]);
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [autoAssign, setAutoAssign] = useState(true);
  const [projectId, setProjectId] = useState<string | undefined>(defaultProjectId);
  const [agentId, setAgentId] = useState<string | undefined>();
  const [priority, setPriority] = useState<string | undefined>();
  const [dueAt, setDueAt] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [dragOver, setDragOver] = useState(false);
  const dragDepth = useRef(0);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const projects = projectsData?.data ?? [];
  const agents = (agentsData?.data ?? []).filter((a) => a.status !== "archived");

  const reset = () => {
    setBrief("");
    setFiles([]);
    setShowAdvanced(false);
    setAutoAssign(true);
    setProjectId(defaultProjectId);
    setAgentId(undefined);
    setPriority(undefined);
    setDueAt("");
    setDragOver(false);
    dragDepth.current = 0;
    if (fileInputRef.current) fileInputRef.current.value = "";
  };

  const addFiles = (incoming: FileList | File[]) => {
    const next = Array.from(incoming);
    if (next.length === 0) return;
    setFiles((prev) => [...prev, ...next]);
  };

  const removeFile = (index: number) => {
    setFiles((prev) => prev.filter((_, i) => i !== index));
  };

  const onDragEnter = (e: React.DragEvent) => {
    if (![...e.dataTransfer.types].includes("Files")) return;
    e.preventDefault();
    dragDepth.current += 1;
    setDragOver(true);
  };

  const onDragLeave = () => {
    dragDepth.current = Math.max(0, dragDepth.current - 1);
    if (dragDepth.current === 0) setDragOver(false);
  };

  const onDrop = (e: React.DragEvent) => {
    e.preventDefault();
    dragDepth.current = 0;
    setDragOver(false);
    addFiles(e.dataTransfer.files);
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

      // Attach staged files before kicking off the agent so the run sees them.
      if (files.length > 0) {
        try {
          await Promise.all(
            files.map((file) => attachFile.mutateAsync({ file, taskId: created.data.id })),
          );
        } catch {
          toast({
            tone: "error",
            title: "Some files failed to attach",
            description: "The task was created, but not all documents could be uploaded.",
          });
        }
      }

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

        <div
          onDragEnter={onDragEnter}
          onDragOver={(e) => {
            if ([...e.dataTransfer.types].includes("Files")) e.preventDefault();
          }}
          onDragLeave={onDragLeave}
          onDrop={onDrop}
          className={cn(
            "rounded-xl border-2 border-dashed p-3 transition-colors",
            dragOver
              ? "border-primary bg-primary-muted/30"
              : "border-border/60 hover:border-primary/40",
          )}
        >
          <input
            ref={fileInputRef}
            type="file"
            multiple
            className="hidden"
            onChange={(e) => {
              if (e.target.files) addFiles(e.target.files);
              e.target.value = "";
            }}
          />

          {files.length > 0 && (
            <div className="mb-2.5 flex flex-wrap gap-1.5">
              {files.map((file, index) => (
                <span
                  key={`${file.name}-${file.size}-${index}`}
                  className="flex items-center gap-1.5 rounded-md border border-border bg-surface-raised px-2 py-1"
                >
                  <Paperclip size={11} className="shrink-0 text-primary-light" />
                  <span className="max-w-[140px] truncate text-[11px] text-text">{file.name}</span>
                  <span className="text-[10px] text-text-muted">{formatSize(file.size)}</span>
                  <button
                    type="button"
                    aria-label={`Remove ${file.name}`}
                    onClick={() => removeFile(index)}
                    className="text-text-muted hover:text-danger"
                  >
                    <X size={11} />
                  </button>
                </span>
              ))}
            </div>
          )}

          <button
            type="button"
            onClick={() => fileInputRef.current?.click()}
            className="flex w-full flex-col items-center gap-1.5 rounded-lg px-2 py-2 text-center transition-colors hover:bg-surface-hover/50 mk-focus-ring"
          >
            <span
              className={cn(
                "flex h-8 w-8 items-center justify-center rounded-full",
                dragOver ? "bg-primary/20 text-primary-light" : "bg-surface-raised text-text-muted",
              )}
            >
              <Upload size={15} />
            </span>
            <span className="text-xs font-medium text-text">
              {dragOver ? "Drop files to attach" : "Drop files or click to browse"}
            </span>
            <span className="text-[11px] text-text-muted">PDF, DOC, CSV, images…</span>
          </button>
        </div>

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
