import { useId, useState, type FormEvent } from "react";
import { CheckCircle2, Send, ThumbsDown, ThumbsUp } from "lucide-react";
import type { Task } from "@/api/types";
import { useTaskResponseFeedback } from "@/api/task-feedback";
import { Button } from "@/components/ui/button";
import { useAuthStore } from "@/stores/auth-store";
import { useTaskFeedbackStore } from "@/stores/task-feedback-store";

type FeedbackTask = Pick<
  Task,
  | "id"
  | "latest_run"
  | "response_feedback"
  | "assigned_agent_id"
  | "pending_approval"
>;

/** Feedback concerns the response; improvements resume the same task with the user's prompt. */
export function TaskResponseFeedback({ task }: { task: FeedbackTask }) {
  const workspaceId = useAuthStore((state) => state.workspaceId);
  const runId = task.latest_run?.id;
  if (
    !task.latest_run ||
    ["running", "queued"].includes(task.latest_run.status) ||
    task.pending_approval?.tool_name === "export_pdf"
  )
    return null;
  // Remount mutation state when the user changes task or a new result arrives.
  return <ResponseFeedbackForm key={`${workspaceId}:${task.id}:${runId}`} task={task} />;
}

function ResponseFeedbackForm({ task }: { task: FeedbackTask }) {
  const workspaceId = useAuthStore((state) => state.workspaceId);
  const runId = task.latest_run?.id;
  const draftKey = `${workspaceId}:${task.id}:${runId ?? "no-run"}`;
  const draft = useTaskFeedbackStore((state) => state.drafts[draftKey]);
  const setDraft = useTaskFeedbackStore((state) => state.setDraft);
  const feedback = useTaskResponseFeedback();
  const [submitted, setSubmitted] = useState<"good" | "needs_improvement" | null>(null);
  const inputId = useId();
  const prompt = draft?.prompt ?? "";
  const editing = draft?.editing ?? false;
  const hasResponse =
    Boolean(task.latest_run?.output?.summary?.trim()) ||
    (task.latest_run?.output?.artifacts?.length ?? 0) > 0;
  const canRateGood = task.latest_run?.status === "completed" && hasResponse;
  const accepted =
    submitted === "good" ||
    (task.response_feedback?.rating === "good" &&
      task.response_feedback.run_id === (runId ?? null));

  const markGood = () => {
    if (feedback.isPending || !canRateGood) return;
    feedback.mutate(
      { taskId: task.id, rating: "good", ...(runId ? { run_id: runId } : {}) },
      {
        onSuccess: () => {
          setSubmitted("good");
        },
      },
    );
  };

  const requestImprovement = () => {
    feedback.reset();
    setDraft(draftKey, { prompt, editing: true });
  };

  const continueTask = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!prompt.trim() || feedback.isPending || !task.assigned_agent_id) return;
    feedback.mutate(
      {
        taskId: task.id,
        rating: "needs_improvement",
        prompt: prompt.trim(),
        ...(runId ? { run_id: runId } : {}),
      },
      {
        onSuccess: () => {
          setSubmitted("needs_improvement");
        },
      },
    );
  };

  if (submitted === "needs_improvement") {
    return (
      <p role="status" className="text-xs text-text-secondary">
        Your instructions were sent. The agent is continuing this task.
      </p>
    );
  }

  return (
    <section aria-label="Response feedback" className="rounded-xl bg-surface-raised/50 px-4 py-3.5">
      <p className="text-[12px] font-semibold text-text">
        {hasResponse ? "How was the response?" : "The task needs your instructions"}
      </p>
      {!hasResponse && (
        <p className="mt-1.5 text-xs text-text-secondary">
          Tell the agent how to continue and finish this task.
        </p>
      )}
      {accepted && (
        <p role="status" className="mt-1.5 flex items-center gap-1.5 text-xs text-success">
          <CheckCircle2 size={13} /> Thanks for your feedback.
        </p>
      )}
      <div className="mt-3 flex flex-wrap gap-2">
        <Button
          type="button"
          size="sm"
          variant={accepted ? "primary" : "secondary"}
          aria-pressed={accepted && !editing}
          disabled={!canRateGood || feedback.isPending || (accepted && !editing)}
          onClick={markGood}
        >
          <ThumbsUp size={12} /> Good response
        </Button>
        <Button
          type="button"
          size="sm"
          variant={editing ? "primary" : "secondary"}
          aria-pressed={editing}
          disabled={feedback.isPending}
          onClick={requestImprovement}
        >
          <ThumbsDown size={12} /> Needs improvement
        </Button>
      </div>
      {editing && (
        <form className="mt-3 space-y-2" onSubmit={continueTask}>
          <label htmlFor={inputId} className="block text-xs text-text-secondary">
            What should the agent improve?
          </label>
          <textarea
            id={inputId}
            autoFocus
            rows={3}
            value={prompt}
            disabled={feedback.isPending}
            onChange={(event) => setDraft(draftKey, { prompt: event.target.value, editing: true })}
            placeholder="Tell the agent what to change or continue…"
            className="mk-input min-h-24 w-full resize-y text-xs"
          />
          {!task.assigned_agent_id && (
            <p className="text-xs text-text-secondary">Assign an agent to continue this task.</p>
          )}
          <Button
            type="submit"
            size="sm"
            loading={feedback.isPending}
            disabled={!prompt.trim() || !task.assigned_agent_id}
          >
            <Send size={12} /> Continue task
          </Button>
        </form>
      )}
      {feedback.isError && (
        <p role="alert" className="mt-2 text-xs text-danger">
          Could not send your feedback. Your instructions are saved. Please try again.
        </p>
      )}
    </section>
  );
}
