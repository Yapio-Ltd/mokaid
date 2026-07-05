import React, { useMemo, useState } from "react";
import {
  AlertTriangle,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Circle,
  Clock,
  Download,
  FileText,
  Image as ImageIcon,
  Loader2,
  Music,
  Paperclip,
  Send,
  Sparkles,
  ThumbsUp,
  Undo2,
  User,
} from "lucide-react";
import { apiFetch } from "@/api/client";
import type { Envelope, TaskAttachment, TaskRunToolCall } from "@/api/types";
import {
  useAgents,
  useCreateTaskComment,
  useProjects,
  useTask,
  useToggleSubtask,
  useUpdateTask,
} from "@/api/hooks";
import { DetailPanel } from "@/components/ui/detail-panel";
import { Avatar } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Select } from "@/components/ui/select";
import { PriorityBadge, TaskStatusBadge } from "@/components/ui/status";
import { formatBytes, formatDateTime } from "@/lib/format";

const NO_PROJECT = "__none__";
const NO_AGENT = "__none__";

function toDatetimeLocal(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

function fileIcon(mime: string | null) {
  if (!mime) return <FileText size={14} />;
  if (mime.startsWith("image/")) return <ImageIcon size={14} />;
  if (mime.startsWith("audio/")) return <Music size={14} />;
  return <FileText size={14} />;
}

interface ProducedDoc {
  title: string;
  content: string;
}

function producedDocs(toolCalls: TaskRunToolCall[]): ProducedDoc[] {
  return toolCalls.flatMap((call) => {
    const out = call.output;
    if (!out || typeof out !== "object") return [];
    if (call.tool === "draft_document" && typeof out.content === "string")
      return [{ title: typeof out.title === "string" ? out.title : "Document", content: out.content }];
    if (call.tool === "summarize" && typeof out.summary === "string" && out.summary)
      return [{ title: "Summary", content: out.summary }];
    if (call.tool === "generate_report" && out.report)
      return [{ title: "Report", content: JSON.stringify(out.report, null, 2) }];
    if (call.tool === "analyze_file" && typeof out.analysis === "string")
      return [{ title: "Analysis", content: out.analysis }];
    return [];
  });
}

function Section({
  title,
  count,
  icon,
  children,
  defaultOpen = true,
}: {
  title: string;
  count?: number;
  icon?: React.ReactNode;
  children: React.ReactNode;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div>
      <button
        type="button"
        onClick={() => setOpen(!open)}
        className="flex w-full items-center gap-1.5 py-1.5 text-left mk-focus-ring"
      >
        {open ? (
          <ChevronDown size={12} className="text-text-muted" />
        ) : (
          <ChevronRight size={12} className="text-text-muted" />
        )}
        {icon}
        <span className="text-[11px] font-semibold uppercase tracking-wider text-text-muted">
          {title}
        </span>
        {count != null && (
          <span className="ml-auto rounded-full bg-surface-raised px-1.5 py-0.5 text-[10px] tabular-nums text-text-muted">
            {count}
          </span>
        )}
      </button>
      {open && <div className="mt-2">{children}</div>}
    </div>
  );
}

function FileRow({ file }: { file: TaskAttachment }) {
  const [busy, setBusy] = useState(false);
  const download = async () => {
    setBusy(true);
    try {
      const res = await apiFetch<Envelope<{ url: string; name: string }>>(
        `/api/drive/${file.id}/download`,
      );
      window.open(res.data.url, "_blank", "noopener");
    } finally {
      setBusy(false);
    }
  };
  return (
    <button
      type="button"
      onClick={download}
      disabled={busy}
      className="group flex w-full items-center gap-2.5 rounded-xl bg-surface-raised/60 px-3.5 py-2.5 text-left transition-all hover:bg-surface-hover hover:shadow-[0_2px_8px_rgba(0,0,0,0.12)] mk-focus-ring"
    >
      <span className="flex h-8 w-8 items-center justify-center rounded-lg bg-primary-muted/40 text-primary-light">
        {fileIcon(file.mime_type)}
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-xs font-medium text-text">{file.name}</span>
        <span className="text-[10px] text-text-muted">
          {file.size_bytes ? formatBytes(file.size_bytes) : "·"} · {formatDateTime(file.inserted_at)}
        </span>
      </span>
      {busy ? (
        <Loader2 size={13} className="shrink-0 animate-spin text-text-muted" />
      ) : (
        <Download
          size={13}
          className="shrink-0 text-text-muted opacity-0 transition-opacity group-hover:opacity-100"
        />
      )}
    </button>
  );
}

function MetaRow({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-center justify-between gap-3 py-2">
      <span className="shrink-0 text-[11px] text-text-muted">{label}</span>
      <div className="min-w-0">{children}</div>
    </div>
  );
}

export function TaskDetailPanel({
  taskId,
  onClose,
}: {
  taskId: string | null;
  onClose: () => void;
}) {
  const [comment, setComment] = useState("");
  const [expandedDoc, setExpandedDoc] = useState<number | null>(0);

  const { data: taskData, isLoading } = useTask(taskId);
  const { data: agentsData } = useAgents();
  const { data: projectsData } = useProjects();
  const createComment = useCreateTaskComment();
  const toggleSubtask = useToggleSubtask();
  const updateTask = useUpdateTask();

  const task = taskData?.data ?? null;
  const agents = agentsData?.data ?? [];
  const projects = projectsData?.data ?? [];

  const editable = useMemo(() => {
    if (!task) return false;
    if (["completed", "canceled"].includes(task.status)) return false;
    if (task.due_at && new Date(task.due_at).getTime() < Date.now()) return false;
    return true;
  }, [task]);

  const outputs = task?.attachments.filter((f) => f.source === "output") ?? [];
  const inputs = task?.attachments.filter((f) => f.source === "input") ?? [];
  const run = task?.latest_run ?? null;
  const docs = useMemo(() => producedDocs(run?.output?.tool_calls ?? []), [run]);
  const agentWorking =
    run != null && ["queued", "running", "waiting_for_approval"].includes(run.status);
  const runFailed = run?.status === "failed" && task?.status !== "completed";

  const submitComment = () => {
    if (!task || !comment.trim()) return;
    createComment.mutate(
      { taskId: task.id, body: comment.trim() },
      { onSuccess: () => setComment("") },
    );
  };

  const patch = (body: Record<string, unknown>) => {
    if (!task) return;
    updateTask.mutate({ id: task.id, ...body });
  };

  return (
    <DetailPanel open={taskId != null} onClose={onClose} title="Task Details">
      {isLoading && (
        <div className="flex items-center justify-center py-16 text-text-muted">
          <Loader2 size={18} className="animate-spin" />
        </div>
      )}

      {task && (
        <div className="flex flex-col gap-5 px-5 pb-5 pt-2">
          {/* Header */}
          <div>
            <h3 className="text-[15px] font-bold leading-snug text-text">{task.title}</h3>
            {task.description && (
              <p className="mt-1.5 text-[12px] leading-relaxed text-text-secondary">
                {task.description}
              </p>
            )}
            <div className="mt-3 flex flex-wrap items-center gap-1.5">
              <TaskStatusBadge status={task.status} />
              <PriorityBadge priority={task.priority} />
              {task.tags.map((tag) => (
                <Badge key={tag} tone="muted">{tag}</Badge>
              ))}
            </div>
          </div>

          {/* Status banners */}
          {agentWorking && (
            <div className="flex items-center gap-3 rounded-xl bg-info/8 px-4 py-3.5">
              <div className="relative flex items-center justify-center">
                <span className="absolute inline-flex h-5 w-5 animate-ping rounded-full bg-info/30" />
                <Loader2 size={16} className="relative animate-spin text-info" />
              </div>
              <p className="text-[12px] leading-snug text-text-secondary">
                <span className="font-semibold text-text">
                  {task.assigned_agent_name ?? "Agent"}
                </span>{" "}
                is working…
              </p>
            </div>
          )}

          {task.status === "in_review" && !agentWorking && (
            <div className="rounded-xl bg-primary/8 px-4 py-3.5">
              <div className="flex items-center gap-2.5">
                <Sparkles size={15} className="shrink-0 text-primary" />
                <p className="text-[12px] leading-snug text-text-secondary">
                  <span className="font-semibold text-text">Ready for review</span>. Check the
                  output below.
                </p>
              </div>
              <div className="mt-3 flex gap-2">
                <Button
                  size="sm"
                  className="flex-1 gap-1.5"
                  loading={updateTask.isPending}
                  onClick={() => patch({ status: "completed" })}
                >
                  <ThumbsUp size={12} /> Approve
                </Button>
                <Button
                  size="sm"
                  variant="secondary"
                  className="flex-1 gap-1.5"
                  onClick={() => patch({ status: "in_progress" })}
                >
                  <Undo2 size={12} /> Revise
                </Button>
              </div>
            </div>
          )}

          {runFailed && (
            <div className="flex items-start gap-2.5 rounded-xl bg-danger/8 px-4 py-3.5">
              <AlertTriangle size={15} className="mt-0.5 shrink-0 text-danger" />
              <div>
                <p className="text-[12px] font-semibold text-danger">Run failed</p>
                <p className="mt-0.5 text-[11px] leading-snug text-text-secondary">
                  {run?.error || "An unexpected error occurred."}
                </p>
              </div>
            </div>
          )}

          {/* Metadata */}
          <div className="rounded-xl bg-surface-raised/40 px-4 py-1">
            <MetaRow label="Agent">
              {editable ? (
                <Select
                  className="h-7 w-full text-[11px]"
                  value={task.assigned_agent_id ?? NO_AGENT}
                  onValueChange={(v) =>
                    patch({ assigned_agent_id: v === NO_AGENT ? null : v })
                  }
                  options={[
                    { value: NO_AGENT, label: "Unassigned" },
                    ...agents.map((a) => ({ value: a.id, label: a.display_name })),
                  ]}
                />
              ) : (
                <span className="flex items-center gap-1.5 text-xs text-text">
                  <Avatar
                    name={task.assigned_agent_name}
                    size="xs"
                    isAi={task.assigned_agent_kind === "ai"}
                  />
                  {task.assigned_agent_name ?? "Unassigned"}
                </span>
              )}
            </MetaRow>

            <MetaRow label="Project">
              {editable ? (
                <Select
                  className="h-7 w-full text-[11px]"
                  value={task.project_id ?? NO_PROJECT}
                  onValueChange={(v) =>
                    patch({ project_id: v === NO_PROJECT ? null : v })
                  }
                  options={[
                    { value: NO_PROJECT, label: "No project" },
                    ...projects.map((p) => ({ value: p.id, label: p.name })),
                  ]}
                />
              ) : (
                <span className="text-xs text-text">{task.project_name ?? "None"}</span>
              )}
            </MetaRow>

            <MetaRow label="Due">
              {editable ? (
                <input
                  type="datetime-local"
                  className="mk-input h-7 w-full text-[11px]"
                  value={toDatetimeLocal(task.due_at)}
                  onChange={(e) =>
                    patch({
                      due_at: e.target.value ? new Date(e.target.value).toISOString() : null,
                    })
                  }
                />
              ) : (
                <span className="flex items-center gap-1.5 text-xs text-text">
                  <Clock size={12} className="text-text-muted" />
                  {task.due_at ? formatDateTime(task.due_at) : "None"}
                </span>
              )}
            </MetaRow>

            <MetaRow label="Created">
              <span className="text-xs text-text-muted">{formatDateTime(task.inserted_at)}</span>
            </MetaRow>
          </div>

          {/* Progress */}
          {task.progress_percent > 0 && task.status !== "completed" && (
            <div className="rounded-xl bg-surface-raised/40 px-4 py-3">
              <div className="mb-2 flex justify-between text-[11px]">
                <span className="text-text-muted">Progress</span>
                <span className="font-bold tabular-nums text-text">
                  {task.progress_percent}%
                </span>
              </div>
              <div className="h-1.5 overflow-hidden rounded-full bg-surface-raised">
                <div
                  className="h-full rounded-full bg-primary transition-all"
                  style={{ width: `${task.progress_percent}%` }}
                />
              </div>
            </div>
          )}

          {/* Output */}
          {(outputs.length > 0 || docs.length > 0) && (
            <Section
              title="Output"
              count={outputs.length + docs.length}
              icon={<Sparkles size={11} className="text-primary" />}
            >
              <div className="space-y-2">
                {outputs.map((f) => (
                  <FileRow key={f.id} file={f} />
                ))}
                {docs.map((doc, i) => (
                  <div key={i} className="overflow-hidden rounded-xl bg-surface-raised/60">
                    <button
                      type="button"
                      onClick={() => setExpandedDoc(expandedDoc === i ? null : i)}
                      className="flex w-full items-center gap-2 px-3.5 py-2.5 text-left transition-colors hover:bg-surface-hover mk-focus-ring"
                    >
                      <FileText size={13} className="shrink-0 text-primary" />
                      <span className="min-w-0 flex-1 truncate text-xs font-medium text-text">
                        {doc.title}
                      </span>
                      <span className="rounded-md bg-surface-raised px-2 py-0.5 text-[10px] text-text-muted">
                        {expandedDoc === i ? "Hide" : "View"}
                      </span>
                    </button>
                    {expandedDoc === i && (
                      <pre className="max-h-48 overflow-y-auto bg-bg-deep/50 px-3.5 py-3 font-sans text-[11px] leading-relaxed text-text-secondary">
                        {doc.content}
                      </pre>
                    )}
                  </div>
                ))}
              </div>
            </Section>
          )}

          {/* Attachments */}
          {inputs.length > 0 && (
            <Section
              title="Attachments"
              count={inputs.length}
              icon={<Paperclip size={11} className="text-text-muted" />}
            >
              <div className="space-y-2">
                {inputs.map((f) => (
                  <FileRow key={f.id} file={f} />
                ))}
              </div>
            </Section>
          )}

          {/* Subtasks */}
          {task.subtasks.length > 0 && (
            <Section
              title="Subtasks"
              count={task.subtask_done_count}
              icon={<CheckCircle2 size={11} className="text-text-muted" />}
            >
              <div className="space-y-0.5">
                {task.subtasks
                  .slice()
                  .sort((a, b) => a.position - b.position)
                  .map((st) => (
                    <button
                      key={st.id}
                      type="button"
                      onClick={() =>
                        toggleSubtask.mutate({
                          taskId: task.id,
                          subtaskId: st.id,
                          done: !st.done,
                        })
                      }
                      className="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-xs transition-colors hover:bg-surface-hover mk-focus-ring"
                    >
                      {st.done ? (
                        <CheckCircle2 size={14} className="shrink-0 text-success" />
                      ) : (
                        <Circle size={14} className="shrink-0 text-text-muted/50" />
                      )}
                      <span className={st.done ? "text-text-muted line-through" : "text-text"}>
                        {st.title}
                      </span>
                    </button>
                  ))}
              </div>
            </Section>
          )}

          {/* Activity */}
          <Section
            title="Activity"
            count={task.comments.length || undefined}
            icon={<User size={11} className="text-text-muted" />}
          >
            {task.comments.length > 0 && (
              <div className="mb-3 space-y-3">
                {task.comments.map((c) => (
                  <div key={c.id} className="flex gap-2.5">
                    <Avatar
                      name={c.author_name}
                      size="xs"
                      isAi={c.author_kind === "agent"}
                    />
                    <div className="min-w-0 flex-1">
                      <p className="text-[11px]">
                        <span className="font-semibold text-text">
                          {c.author_name ?? "Unknown"}
                        </span>
                        <span className="ml-1.5 text-text-muted">
                          {formatDateTime(c.inserted_at)}
                        </span>
                      </p>
                      <p className="mt-0.5 whitespace-pre-wrap text-xs leading-relaxed text-text-secondary">
                        {c.body}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            )}

            <div className="flex gap-2">
              <input
                value={comment}
                onChange={(e) => setComment(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && submitComment()}
                placeholder="Write a comment…"
                className="mk-input flex-1 text-xs"
              />
              <Button
                size="icon"
                variant="secondary"
                onClick={submitComment}
                loading={createComment.isPending}
                aria-label="Send comment"
              >
                <Send size={13} />
              </Button>
            </div>
          </Section>
        </div>
      )}
    </DetailPanel>
  );
}
