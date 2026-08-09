import { useMemo, useState } from "react";
import {
  Activity,
  AlertTriangle,
  Ban,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Clock,
  History,
  Loader2,
  ShieldAlert,
  ThumbsDown,
} from "lucide-react";
import { motion } from "framer-motion";
import type { TaskRun, ToolActivityEvent } from "@/api/types";
import { useTaskRuns } from "@/api/hooks";
import { useToolActivityStore } from "@/stores/tool-activity-store";
import { cn } from "@/lib/cn";
import { formatDateTime, formatRelative } from "@/lib/format";

function formatDuration(ms: number | undefined): string {
  if (!ms || ms < 0) return "";
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.floor(ms / 60_000)}m ${Math.round((ms % 60_000) / 1000)}s`;
}

function StatusIcon({ status }: { status: string }) {
  switch (status) {
    case "running":
      return <Loader2 size={12} className="shrink-0 animate-spin text-info" />;
    case "awaiting_approval":
      return <ShieldAlert size={12} className="shrink-0 text-warning" />;
    case "ok":
      return <CheckCircle2 size={12} className="shrink-0 text-success" />;
    case "error":
      return <AlertTriangle size={12} className="shrink-0 text-danger" />;
    case "denied":
      return <Ban size={12} className="shrink-0 text-danger" />;
    case "rejected":
      return <ThumbsDown size={12} className="shrink-0 text-warning" />;
    default:
      return <Clock size={12} className="shrink-0 text-text-muted" />;
  }
}

/** Merge the persisted feed with live channel events (live wins, matched by id). */
function mergeFeeds(
  persisted: ToolActivityEvent[],
  live: ToolActivityEvent[],
): ToolActivityEvent[] {
  const events = new Map<string, ToolActivityEvent>();
  for (const event of persisted) events.set(event.id, event);
  for (const event of live) {
    const existing = events.get(event.id);
    events.set(event.id, existing ? { ...existing, ...event } : event);
  }
  return [...events.values()];
}

function ActivityList({ events }: { events: ToolActivityEvent[] }) {
  return (
    <ul className="space-y-1">
      {events.map((event) => (
        <motion.li
          key={event.id}
          initial={{ opacity: 0, y: 4 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.15 }}
          className="flex items-start gap-2 text-[11px] leading-snug"
        >
          <span className="mt-0.5">
            <StatusIcon status={event.status} />
          </span>
          <span
            className={cn(
              "min-w-0 flex-1",
              event.status === "running" || event.status === "awaiting_approval"
                ? "font-medium text-text"
                : event.status === "error" || event.status === "denied"
                  ? "text-danger/80"
                  : "text-text-secondary",
            )}
          >
            {event.description || event.tool}
          </span>
          {event.duration_ms != null && event.duration_ms > 0 && (
            <span className="shrink-0 tabular-nums text-[10px] text-text-muted">
              {formatDuration(event.duration_ms)}
            </span>
          )}
        </motion.li>
      ))}
    </ul>
  );
}

/**
 * Chronological feed of everything the agent does during the current run:
 * persisted events from the run + live events streamed over the workspace
 * channel (spinners resolve in place as tools finish).
 */
export function RunTimeline({
  taskId,
  run,
  working,
}: {
  taskId: string;
  run: TaskRun | null;
  working: boolean;
}) {
  const liveFeed = useToolActivityStore((s) => s.feeds[taskId]);
  const [open, setOpen] = useState(true);

  const events = useMemo(() => {
    // Event ids are prefixed with the run id — keep only the current run's
    // live events so a retried mission doesn't show the previous run's feed.
    const live = run?.id
      ? (liveFeed ?? []).filter((e) => e.id.startsWith(`${run.id}:`))
      : (liveFeed ?? []);
    return mergeFeeds(run?.tool_activity ?? [], live);
  }, [run?.id, run?.tool_activity, liveFeed]);

  if (events.length === 0) return null;

  const runningCount = events.filter((e) => e.status === "running").length;

  return (
    <div className="rounded-xl border border-border bg-surface-raised/60 px-4 py-3">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        className="flex w-full items-center justify-between"
      >
        <span className="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider text-text-muted">
          <Activity size={11} className={cn(working ? "text-info" : "text-primary-light")} />
          Activity
          {working && runningCount > 0 && (
            <span className="ml-1 inline-flex h-1.5 w-1.5 animate-pulse rounded-full bg-info" />
          )}
        </span>
        <span className="flex items-center gap-1.5 text-[10px] tabular-nums text-text-muted">
          {events.length}
          {open ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
        </span>
      </button>
      {open && (
        <div className="mt-2 max-h-64 overflow-y-auto pr-1">
          <ActivityList events={events} />
        </div>
      )}
    </div>
  );
}

const RUN_STATUS_LABELS: Record<string, string> = {
  queued: "Queued",
  running: "Running",
  waiting_for_approval: "Waiting for approval",
  waiting_for_user_input: "Waiting for input",
  completed: "Completed",
  failed: "Failed",
  canceled: "Canceled",
};

function RunHistoryEntry({ run }: { run: TaskRun }) {
  const [open, setOpen] = useState(false);
  const events = run.tool_activity ?? [];
  const startedAt = run.started_at ?? run.inserted_at;

  return (
    <div className="rounded-lg bg-surface-raised/50 px-3 py-2">
      <button
        type="button"
        className="flex w-full items-center gap-2 text-left"
        onClick={() => setOpen(!open)}
        disabled={events.length === 0 && !run.error}
      >
        <span
          className={cn(
            "inline-flex h-1.5 w-1.5 shrink-0 rounded-full",
            run.status === "completed"
              ? "bg-success"
              : run.status === "failed"
                ? "bg-danger"
                : ["running", "queued", "waiting_for_approval"].includes(run.status)
                  ? "bg-info"
                  : "bg-text-muted/50",
          )}
        />
        <span className="min-w-0 flex-1 truncate text-[11px] font-medium text-text">
          {RUN_STATUS_LABELS[run.status] ?? run.status}
        </span>
        <span className="shrink-0 text-[10px] text-text-muted" title={formatDateTime(startedAt)}>
          {formatRelative(startedAt)}
        </span>
        {(events.length > 0 || run.error) &&
          (open ? (
            <ChevronDown size={12} className="shrink-0 text-text-muted" />
          ) : (
            <ChevronRight size={12} className="shrink-0 text-text-muted" />
          ))}
      </button>
      {open && (
        <div className="mt-2 space-y-2">
          {run.error && (
            <p className="rounded-md bg-danger/8 px-2 py-1.5 text-[10px] leading-snug text-danger/80">
              {run.error}
            </p>
          )}
          {events.length > 0 && <ActivityList events={events} />}
        </div>
      )}
    </div>
  );
}

/** All past runs of the task (the current run already has its own timeline). */
export function RunHistory({
  taskId,
  currentRunId,
}: {
  taskId: string;
  currentRunId: string | null;
}) {
  const [open, setOpen] = useState(false);
  const { data } = useTaskRuns(taskId, { enabled: open });
  const runs = (data?.data ?? []).filter((r) => r.id !== currentRunId);

  return (
    <div>
      <button
        type="button"
        onClick={() => setOpen(!open)}
        className="flex w-full items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider text-text-muted transition-colors hover:text-text"
      >
        <History size={11} />
        Run history
        {open ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
      </button>
      {open && (
        <div className="mt-2 space-y-1.5">
          {runs.length === 0 ? (
            <p className="text-[11px] text-text-muted">No previous runs.</p>
          ) : (
            runs.map((run) => <RunHistoryEntry key={run.id} run={run} />)
          )}
        </div>
      )}
    </div>
  );
}
