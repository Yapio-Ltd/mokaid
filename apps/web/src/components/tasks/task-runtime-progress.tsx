import { CheckCircle2, Circle, FileText, Users } from "lucide-react";
import type { TaskRuntime } from "@mokaid/shared-types";
import type { TaskAttachment } from "@/api/types";
import { openDeliverable } from "@/stores/deliverable-store";
import { RuntimeBudgetActions } from "./runtime-budget-actions";

const STATUS_LABELS: Record<string, string> = {
  queued: "Queued",
  running: "Working",
  in_progress: "Working",
  completed: "Completed",
  failed: "Could not finish",
  canceled: "Stopped",
  cancelled: "Stopped",
  waiting_for_budget: "Paused: credit limit reached",
  budget_exhausted: "Paused: credit limit reached",
  waiting_for_approval: "Waiting for your approval",
  waiting_for_user_input: "Waiting for your input",
  collecting: "Combining contributions",
  verifying: "Checking the result",
};
export function runtimeStatusLabel(status: string): string {
  return STATUS_LABELS[status] ?? status.replaceAll("_", " ");
}
function credits(value: unknown): string {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? value.toLocaleString("en-US", { maximumFractionDigits: 2 })
    : "Unavailable";
}

/** Optional, additive UI: older runs have no runtime and keep their existing view. */
export function TaskRuntimeProgress({
  runtime,
  attachments = [],
  taskId,
  runId,
}: {
  runtime?: TaskRuntime | null;
  attachments?: TaskAttachment[];
  taskId?: string;
  runId?: string;
}) {
  if (!runtime || runtime.engine !== "openai_agents") return null;
  const participants = Array.isArray(runtime.participants) ? runtime.participants : [];
  const checks = Array.isArray(runtime.verification?.checks) ? runtime.verification.checks : [];
  const files = new Map<string, { id: string; name: string; mime_type: string | null }>();
  // A manifest (including an empty one during execution) identifies this run's
  // saved work. Do not present older task attachments as its new deliverables.
  if (!Array.isArray(runtime.manifest)) {
    for (const file of attachments) {
      if (file.source === "output") files.set(file.id, file);
    }
  }
  for (const file of runtime.manifest ?? []) {
    if (file.id && file.filename)
      files.set(file.id, { id: file.id, name: file.filename, mime_type: file.mime_type ?? null });
  }
  const budgetPaused = ["waiting_for_budget", "budget_exhausted"].includes(runtime.status);

  return (
    <section
      aria-label="Team execution"
      className="space-y-3 rounded-xl border border-border bg-surface-raised/60 px-4 py-3"
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="flex items-center gap-1.5 text-xs font-semibold text-text">
          <Users size={14} /> Team execution
        </h3>
        <span
          className={budgetPaused ? "text-xs text-warning" : "text-xs text-text-secondary"}
          role="status"
        >
          {runtimeStatusLabel(runtime.status)}
        </span>
      </div>
      {budgetPaused && (
        <p className="text-xs text-text-secondary">
          The mission reached its credit allowance. Review the available results before continuing.
        </p>
      )}
      {budgetPaused && taskId && runId && (
        <RuntimeBudgetActions key={runId} taskId={taskId} runId={runId} />
      )}
      {participants.length > 0 && (
        <ul className="space-y-2" aria-label="Contributors">
          {participants.map((participant) => (
            <li key={participant.agent_id} className="rounded-lg bg-surface/60 px-3 py-2">
              <div className="flex justify-between gap-2 text-xs">
                <span className="font-medium text-text">{participant.name || "Teammate"}</span>
                <span className="text-text-muted">{runtimeStatusLabel(participant.status)}</span>
              </div>
              {participant.assignment && (
                <p className="mt-1 text-[11px] text-text-secondary">{participant.assignment}</p>
              )}
              {!!participant.artifacts?.length && (
                <p className="mt-1 text-[11px] text-text-muted">
                  {participant.artifacts.length} deliverable
                  {participant.artifacts.length === 1 ? "" : "s"}
                </p>
              )}
            </li>
          ))}
        </ul>
      )}
      {runtime.budget && (
        <div aria-label="Mission credits" className="rounded-lg border border-border px-3 py-2">
          <p className="mb-2 text-xs font-medium text-text">Mission credits</p>
          <dl className="grid grid-cols-2 gap-x-4 gap-y-1 text-[11px]">
            <dt className="text-text-muted">Allowance</dt>
            <dd className="text-right tabular-nums">{credits(runtime.budget.limit_credits)}</dd>
            <dt className="text-text-muted">Reserved</dt>
            <dd className="text-right tabular-nums">{credits(runtime.budget.reserved_credits)}</dd>
            <dt className="text-text-muted">{runtime.budget.estimated ? "Estimated used" : "Used"}</dt>
            <dd className="text-right tabular-nums">{credits(runtime.budget.used_credits)}</dd>
            <dt className="text-text-muted">Remaining</dt>
            <dd className="text-right tabular-nums">{credits(runtime.budget.remaining_credits)}</dd>
          </dl>
        </div>
      )}
      {runtime.verification && (
        <div aria-label="Delivery checks" className="space-y-1 text-[11px]">
          <p className="font-medium text-text">
            {checks.length > 0 && runtime.verification.passed === true
              ? "Delivery checks passed"
              : runtime.verification.passed === false
                ? "Delivery needs checking"
                : "Delivery checks pending"}
          </p>
          <ul className="space-y-1">
            {checks.map((check, index) => {
              const name = typeof check === "string" ? check : check.name;
              const passed = typeof check !== "string" && check.passed === true;
              return (
                <li
                  key={`${name}-${index}`}
                  className="flex items-start gap-1.5 text-text-secondary"
                >
                  {passed ? (
                    <CheckCircle2
                      size={12}
                      aria-label="Passed"
                      className="mt-0.5 shrink-0 text-success"
                    />
                  ) : (
                    <Circle
                      size={12}
                      aria-label="Not confirmed"
                      className="mt-0.5 shrink-0 text-text-muted"
                    />
                  )}
                  <span>
                    {name}
                    {typeof check !== "string" && check.message ? ` — ${check.message}` : ""}
                  </span>
                </li>
              );
            })}
          </ul>
        </div>
      )}
      {!!runtime.limitations?.length && (
        <div className="text-[11px] text-warning">
          <p className="font-medium">Limitations</p>
          <ul className="mt-1 list-inside list-disc">
            {runtime.limitations.map((item, index) => (
              <li key={`${item}-${index}`}>{item}</li>
            ))}
          </ul>
        </div>
      )}
      {files.size > 0 && (
        <div className="space-y-1" aria-label="Consolidated deliverables">
          <h4 className="text-xs font-medium text-text">Consolidated deliverables</h4>
          {[...files.values()].map((file) => (
            <button
              key={file.id}
              type="button"
              onClick={() => openDeliverable(file)}
              className="flex w-full items-center gap-2 rounded-md py-1 text-left text-xs text-primary-light mk-focus-ring"
            >
              <FileText size={13} className="shrink-0" />
              <span className="truncate">{file.name}</span>
            </button>
          ))}
        </div>
      )}
    </section>
  );
}
