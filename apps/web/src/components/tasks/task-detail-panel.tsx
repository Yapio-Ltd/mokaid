import { useState } from "react";
import { CheckCircle2, Circle, Send, Sparkles } from "lucide-react";
import type { Task } from "@/api/types";
import { useCreateTaskComment, useExecuteAi } from "@/api/hooks";
import { DetailPanel } from "@/components/ui/detail-panel";
import { Avatar } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { PriorityBadge, TaskStatusBadge } from "@/components/ui/status";
import { ProgressBar } from "@/components/ui/progress-bar";
import { formatDateTime, formatRelative } from "@/lib/format";

export function TaskDetailPanel({ task, onClose }: { task: Task | null; onClose: () => void }) {
  const [comment, setComment] = useState("");
  const createComment = useCreateTaskComment();
  const executeAi = useExecuteAi();

  const submitComment = () => {
    if (!task || !comment.trim()) return;
    createComment.mutate(
      { taskId: task.id, body: comment.trim() },
      { onSuccess: () => setComment("") },
    );
  };

  return (
    <DetailPanel open={task != null} onClose={onClose} title="Task Details">
      {task && (
        <div className="space-y-5 px-5 py-4">
          <div>
            <h3 className="text-sm font-bold leading-snug text-text">{task.title}</h3>
            {task.description && (
              <p className="mt-1.5 text-xs leading-relaxed text-text-secondary">
                {task.description}
              </p>
            )}
          </div>

          <div className="flex flex-wrap items-center gap-2">
            <TaskStatusBadge status={task.status} />
            <PriorityBadge priority={task.priority} />
            {task.tags.map((tag) => (
              <Badge key={tag} tone="muted">
                {tag}
              </Badge>
            ))}
          </div>

          <div className="space-y-1.5 text-xs">
            <div className="flex items-center justify-between">
              <span className="text-text-muted">Assigned to</span>
              <span className="flex items-center gap-1.5 text-text">
                <Avatar
                  name={task.assigned_agent_name}
                  size="xs"
                  isAi={task.assigned_agent_kind === "ai"}
                />
                {task.assigned_agent_name ?? "Unassigned"}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-text-muted">Project</span>
              <span className="text-text">{task.project_name ?? "·"}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-text-muted">Due</span>
              <span className="text-text">{formatDateTime(task.due_at)}</span>
            </div>
          </div>

          {task.progress_percent > 0 && (
            <div>
              <div className="mb-1 flex justify-between text-[11px] text-text-muted">
                <span>Progress</span>
                <span className="font-semibold text-text">{task.progress_percent}%</span>
              </div>
              <ProgressBar value={task.progress_percent} />
            </div>
          )}

          {task.assigned_agent_kind === "ai" && task.status !== "completed" && (
            <Button
              size="sm"
              className="w-full"
              loading={executeAi.isPending}
              onClick={() => executeAi.mutate({ taskId: task.id })}
            >
              <Sparkles size={13} /> Run with AI
            </Button>
          )}

          {task.subtasks.length > 0 && (
            <div>
              <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                Subtasks · {task.subtask_done_count}/{task.subtask_count}
              </p>
              <div className="space-y-1.5">
                {task.subtasks
                  .slice()
                  .sort((a, b) => a.position - b.position)
                  .map((subtask) => (
                    <div key={subtask.id} className="flex items-center gap-2 text-xs">
                      {subtask.done ? (
                        <CheckCircle2 size={14} className="shrink-0 text-success" />
                      ) : (
                        <Circle size={14} className="shrink-0 text-text-muted" />
                      )}
                      <span className={subtask.done ? "text-text-muted line-through" : "text-text"}>
                        {subtask.title}
                      </span>
                    </div>
                  ))}
              </div>
            </div>
          )}

          <div>
            <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
              Comments · {task.comments.length}
            </p>
            <div className="space-y-3">
              {task.comments.map((c) => (
                <div key={c.id} className="flex gap-2">
                  <Avatar name={c.author_name} size="xs" isAi={c.author_kind === "agent"} />
                  <div className="min-w-0 flex-1">
                    <p className="text-[11px]">
                      <span className="font-semibold text-text">{c.author_name}</span>{" "}
                      <span className="text-text-muted">{formatRelative(c.inserted_at)}</span>
                    </p>
                    <p className="mt-0.5 text-xs text-text-secondary">{c.body}</p>
                  </div>
                </div>
              ))}
            </div>

            <div className="mt-3 flex gap-2">
              <input
                value={comment}
                onChange={(e) => setComment(e.target.value)}
                onKeyDown={(e) => e.key === "Enter" && submitComment()}
                placeholder="Add a comment…"
                className="mk-input flex-1"
              />
              <Button
                size="icon"
                variant="secondary"
                onClick={submitComment}
                loading={createComment.isPending}
                aria-label="Send comment"
              >
                <Send size={14} />
              </Button>
            </div>
          </div>
        </div>
      )}
    </DetailPanel>
  );
}
