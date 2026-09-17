import type { CSSProperties } from "react";
import type { Task } from "@/api/types";

const DAY_MS = 24 * 60 * 60 * 1000;
type CompletionTask = Pick<Task, "assigned_agent_id" | "completed_at" | "status">;
type ProgressTask = Pick<
  Task,
  "id" | "title" | "assigned_agent_id" | "status" | "progress_percent"
>;

export interface TaskCompletionBucket {
  /** UTC calendar day, in YYYY-MM-DD format. */
  date: string;
  count: number;
}

interface CompletionWindow {
  agentId?: string;
  days?: number;
  now?: Date;
}

/** Counts only dated, completed task records; never infers dates from updated_at. */
export function getTaskCompletionBuckets(
  tasks: readonly CompletionTask[],
  { agentId, days = 14, now = new Date() }: CompletionWindow = {},
): TaskCompletionBucket[] {
  const dayCount = Number.isFinite(days) ? Math.max(1, Math.min(366, Math.floor(days))) : 14;
  const nowMs = now.getTime();
  if (!Number.isFinite(nowMs)) return [];
  const today = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const start = today - (dayCount - 1) * DAY_MS;
  const buckets = Array.from({ length: dayCount }, (_, index) => ({
    date: new Date(start + index * DAY_MS).toISOString().slice(0, 10),
    count: 0,
  }));

  for (const task of tasks) {
    if (
      task.status !== "completed" ||
      !task.completed_at ||
      (agentId !== undefined && task.assigned_agent_id !== agentId)
    )
      continue;
    const completedAt = Date.parse(task.completed_at);
    if (!Number.isFinite(completedAt) || completedAt < start || completedAt > nowMs) continue;
    const bucket = buckets[Math.floor((completedAt - start) / DAY_MS)];
    if (bucket) bucket.count += 1;
  }
  return buckets;
}

interface ChartAppearance {
  width?: number;
  height?: number;
  color?: string;
  className?: string;
}

export interface TaskActivityChartProps extends ChartAppearance, CompletionWindow {
  /** Undefined means data is unavailable; [] means a loaded, empty task list. */
  tasks: readonly CompletionTask[] | undefined;
}

const chartStyle: CSSProperties = {
  display: "block",
  flexShrink: 0,
  overflow: "visible",
};

function completionSummary(buckets: readonly TaskCompletionBucket[], available: boolean) {
  if (!available || buckets.length === 0) return "Task completion history unavailable";
  const total = buckets.reduce((sum, bucket) => sum + bucket.count, 0);
  const period = `${buckets.length} UTC calendar days (${buckets[0].date} to ${buckets[buckets.length - 1].date})`;
  return total === 0
    ? `Task completion history: no dated completions in loaded task records over the last ${period}`
    : `Task completion history: ${total} completed ${total === 1 ? "task" : "tasks"} in loaded task records over the last ${period}`;
}

function CompletionEmpty({
  width,
  height,
  unavailable,
}: {
  width: number;
  height: number;
  unavailable: boolean;
}) {
  return unavailable ? (
    <text
      x={width / 2}
      y={height / 2}
      textAnchor="middle"
      dominantBaseline="central"
      fill="currentColor"
      opacity={0.45}
      fontSize={width < 70 ? 11 : 8}
    >
      {width < 70 ? "—" : "Unavailable"}
    </text>
  ) : (
    <line
      x1={1}
      y1={height - 2}
      x2={width - 1}
      y2={height - 2}
      stroke="currentColor"
      strokeOpacity={0.24}
      strokeWidth={1}
      strokeDasharray="2 3"
    />
  );
}

/** Daily completion counts, deliberately separate from the agent's performance score. */
export function TaskActivitySparkline({
  tasks,
  agentId,
  days = 14,
  now,
  width = 34,
  height = 18,
  color = "#a68bf5",
  className,
}: TaskActivityChartProps) {
  const buckets = getTaskCompletionBuckets(tasks ?? [], { agentId, days, now });
  const peak = Math.max(0, ...buckets.map((bucket) => bucket.count));
  const baseline = height - 2;
  const points = buckets.map((bucket, index) => ({
    x: buckets.length === 1 ? width / 2 : 1 + (index / (buckets.length - 1)) * (width - 2),
    y: baseline - (bucket.count / Math.max(1, peak)) * (height - 4),
  }));
  // Smooth between recorded days without overshooting either day's count.
  const linePath = points.reduce((path, point, index) => {
    if (index === 0) return `M${point.x},${point.y}`;
    const previous = points[index - 1];
    const middle = (previous.x + point.x) / 2;
    return `${path} C${middle},${previous.y} ${middle},${point.y} ${point.x},${point.y}`;
  }, "");
  const label = completionSummary(buckets, tasks !== undefined);

  return (
    <svg
      className={className}
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      style={{ ...chartStyle, color }}
      role="img"
      aria-label={label}
      data-empty={tasks !== undefined && peak === 0}
    >
      <title>{label}</title>
      <desc>
        {tasks === undefined
          ? "Task records are unavailable."
          : buckets.map((bucket) => `${bucket.date}: ${bucket.count}`).join("; ")}
      </desc>
      {tasks === undefined || peak === 0 ? (
        <CompletionEmpty width={width} height={height} unavailable={tasks === undefined} />
      ) : (
        <>
          <path
            d={`${linePath} L${points[points.length - 1].x},${baseline} L${points[0].x},${baseline} Z`}
            fill="currentColor"
            fillOpacity={0.08}
          />
          <path
            d={linePath}
            stroke="currentColor"
            strokeWidth={1.4}
            strokeLinejoin="round"
            strokeLinecap="round"
            fill="none"
          />
          {buckets.length === 1 && (
            <circle cx={points[0].x} cy={points[0].y} r={1.5} fill="currentColor" />
          )}
        </>
      )}
    </svg>
  );
}

/** Daily task completions in the current window, not lifetime mission completions. */
export function TaskCompletionBars({
  tasks,
  agentId,
  days = 14,
  now,
  width = 116,
  height = 31,
  color = "#cba35d",
  className,
}: TaskActivityChartProps) {
  const buckets = getTaskCompletionBuckets(tasks ?? [], { agentId, days, now });
  const peak = Math.max(0, ...buckets.map((bucket) => bucket.count));
  const slot = width / Math.max(1, buckets.length);
  const barWidth = Math.max(1, slot * 0.6);
  const label = completionSummary(buckets, tasks !== undefined);

  return (
    <svg
      className={className}
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      style={{ ...chartStyle, color }}
      role="img"
      aria-label={label}
      data-empty={tasks !== undefined && peak === 0}
    >
      <title>{label}</title>
      {tasks === undefined || peak === 0 ? (
        <CompletionEmpty width={width} height={height} unavailable={tasks === undefined} />
      ) : (
        buckets.map((bucket, index) => {
          const barHeight = (bucket.count / peak) * (height - 3);
          return (
            <rect
              key={bucket.date}
              x={index * slot + (slot - barWidth) / 2}
              y={height - 1 - barHeight}
              width={barWidth}
              height={barHeight}
              rx={Math.min(1.4, barWidth / 2)}
              fill="currentColor"
              opacity={0.85}
            >
              <title>{`${bucket.date}: ${bucket.count} completed ${bucket.count === 1 ? "task" : "tasks"}`}</title>
            </rect>
          );
        })
      )}
    </svg>
  );
}

export interface TaskProgressBarsProps extends ChartAppearance {
  tasks: readonly ProgressTask[] | undefined;
  agentId?: string;
  maxTasks?: number;
}

/** One bar per active task, with height equal to its persisted progress percentage. */
export function TaskProgressBars({
  tasks,
  agentId,
  maxTasks = 8,
  width = 116,
  height = 31,
  color = "#85a9e4",
  className,
}: TaskProgressBarsProps) {
  const activeTasks = (tasks ?? []).filter(
    (task) =>
      task.status !== "completed" &&
      task.status !== "canceled" &&
      (agentId === undefined || task.assigned_agent_id === agentId),
  );
  const limit = Number.isFinite(maxTasks) ? Math.max(1, Math.floor(maxTasks)) : 8;
  const shownTasks = activeTasks.slice(0, limit);
  const barWidth = Math.min(8, width / Math.max(1, shownTasks.length) - 3);
  const gap = 4;
  const chartWidth = shownTasks.length * (barWidth + gap) - gap;
  const label =
    tasks === undefined
      ? "Active task progress unavailable"
      : activeTasks.length === 0
        ? "Active task progress: no active tasks in loaded task records"
        : `Active task progress: ${shownTasks.length} of ${activeTasks.length} active tasks in loaded task records; each bar shows current completion from 0 to 100%`;

  return (
    <svg
      className={className}
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      style={{ ...chartStyle, color }}
      role="img"
      aria-label={label}
    >
      <title>{label}</title>
      {tasks === undefined || shownTasks.length === 0 ? (
        <CompletionEmpty width={width} height={height} unavailable={tasks === undefined} />
      ) : (
        shownTasks.map((task, index) => {
          const progress = Number.isFinite(task.progress_percent)
            ? Math.max(0, Math.min(100, task.progress_percent))
            : null;
          const filledHeight = ((progress ?? 0) / 100) * (height - 2);
          const x = width - chartWidth + index * (barWidth + gap);
          return (
            <g key={task.id}>
              <title>{`${task.title}: ${progress === null ? "progress unavailable" : `${Math.round(progress)}% complete`}`}</title>
              <rect
                x={x}
                y={1}
                width={barWidth}
                height={height - 2}
                rx={1.8}
                fill="currentColor"
                opacity={0.1}
              />
              <rect
                x={x}
                y={height - 1 - filledHeight}
                width={barWidth}
                height={filledHeight}
                rx={1.8}
                fill="currentColor"
                opacity={0.85}
              />
            </g>
          );
        })
      )}
    </svg>
  );
}

/** A static segmented score meter: no historical performance is inferred. */
export function PerformanceScoreGauge({
  score,
  width = 116,
  height = 31,
  color = "#b798f1",
  className,
}: ChartAppearance & { score: number | null | undefined }) {
  const value = score != null && Number.isFinite(score) ? Math.max(0, Math.min(100, score)) : null;
  const segments = 16;
  const slot = width / segments;
  const barWidth = slot * 0.58;
  const label =
    value === null
      ? "Performance score unavailable"
      : `Current performance score: ${Math.round(value)} out of 100. A combined progression score, not a success rate or historical trend.`;

  return (
    <svg
      className={className}
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      style={{ ...chartStyle, color }}
      role="img"
      aria-label={label}
    >
      <title>{label}</title>
      {value === null ? (
        <CompletionEmpty width={width} height={height} unavailable />
      ) : (
        Array.from({ length: segments }, (_, index) => {
          const barHeight = 5 + (index / (segments - 1)) * (height - 7);
          const filled = Math.max(0, Math.min(1, (value / 100) * segments - index));
          return (
            <g key={index}>
              <rect
                x={index * slot}
                y={height - 1 - barHeight}
                width={barWidth}
                height={barHeight}
                rx={1.5}
                fill="currentColor"
                opacity={0.12}
              />
              {filled > 0 && (
                <rect
                  x={index * slot}
                  y={height - 1 - barHeight}
                  width={barWidth * filled}
                  height={barHeight}
                  rx={1.5}
                  fill="currentColor"
                  opacity={0.85}
                  style={{ filter: "drop-shadow(0 0 3px currentColor)" }}
                />
              )}
            </g>
          );
        })
      )}
    </svg>
  );
}
