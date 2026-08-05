import { useMemo, useState, type DragEvent } from "react";
import { CheckSquare, LayoutGrid, List, Plus } from "lucide-react";
import {
  KANBAN_COLUMNS,
  KANBAN_COLUMN_LABELS,
  kanbanColumnFor,
  type TaskStatus,
} from "@mokaid/shared-types";
import { useTasks, useUpdateTask } from "@/api/hooks";
import type { Task } from "@/api/types";
import { Avatar } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { PriorityBadge, TaskStatusBadge } from "@/components/ui/status";
import { ProgressBar } from "@/components/ui/progress-bar";
import { SearchInput } from "@/components/ui/search-input";
import { SkeletonRows } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/ui/empty-state";
import { NewTaskModal } from "@/components/modals/new-task-modal";
import { PageHeader } from "@/components/ui/page-header";
import { useAuthStore } from "@/stores/auth-store";
import { useActiveProjectId } from "@/stores/project-store";
import { useUiStore } from "@/stores/ui-store";
import { cn } from "@/lib/cn";
import { formatRelative } from "@/lib/format";

type ViewMode = "kanban" | "list";

// Text color drives the mk-glow-dot halo (box-shadow: currentColor).
const columnAccent: Record<string, string> = {
  to_do: "bg-text-muted text-text-muted",
  in_progress: "bg-info text-info",
  completed: "bg-success text-success",
};

function KanbanCard({
  task,
  index,
  flashed,
  onSelect,
  onDragStart,
}: {
  task: Task;
  index: number;
  flashed: boolean;
  onSelect: () => void;
  onDragStart: (e: DragEvent) => void;
}) {
  return (
    <button
      draggable
      onDragStart={onDragStart}
      onClick={onSelect}
      // Cap the stagger so deep columns don't feel sluggish.
      style={{ animationDelay: `${Math.min(index, 8) * 45}ms` }}
      className={cn(
        "mk-tile mk-fade-up w-full cursor-grab space-y-2.5 rounded-xl p-3 text-left active:cursor-grabbing mk-focus-ring",
        // Just-finished run: pulse so the eye lands on what moved.
        flashed && "animate-pulse ring-2 ring-primary shadow-glow",
      )}
    >
      <div className="flex items-start justify-between gap-2">
        <p className="text-xs font-semibold leading-snug text-text">{task.title}</p>
        <PriorityBadge priority={task.priority} />
      </div>
      {/* Sub-state within the merged lanes (waiting for approval, in review…) */}
      {["waiting", "in_review", "blocked", "overdue", "canceled"].includes(task.status) && (
        <TaskStatusBadge status={task.status} />
      )}
      {task.tags.length > 0 && (
        <div className="flex flex-wrap gap-1">
          {task.tags.slice(0, 3).map((tag) => (
            <Badge key={tag} tone="muted">
              {tag}
            </Badge>
          ))}
        </div>
      )}
      {task.progress_percent > 0 && task.status !== "completed" && (
        <ProgressBar value={task.progress_percent} size="xs" />
      )}
      <div className="flex items-center justify-between">
        <span className="flex items-center gap-1.5 text-[11px] text-text-muted">
          <Avatar name={task.assigned_agent_name} size="xs" isAi={task.assigned_agent_kind === "ai"} />
          <span className="max-w-[100px] truncate">{task.assigned_agent_name ?? "Unassigned"}</span>
        </span>
        {task.due_at && (
          <span className="text-[10px] text-text-muted">{formatRelative(task.due_at)}</span>
        )}
      </div>
    </button>
  );
}

export function TasksPage() {
  const [view, setView] = useState<ViewMode>("kanban");
  const [search, setSearch] = useState("");
  const [dragOver, setDragOver] = useState<string | null>(null);
  const [showNewTask, setShowNewTask] = useState(false);

  // Shared selection: the detail panel is rendered globally by AppShell.
  const setSelectedId = useUiStore((s) => s.selectTask);
  const flashedTaskIds = useUiStore((s) => s.flashedTaskIds);

  // Scoped to the project selected in the header (all projects when null).
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const activeProjectId = useActiveProjectId(workspaceId);

  const { data, isLoading } = useTasks(
    activeProjectId ? { project_id: activeProjectId } : {},
  );
  const updateTask = useUpdateTask();

  const tasks = useMemo(() => {
    const list = data?.data ?? [];
    if (!search) return list;
    const q = search.toLowerCase();
    return list.filter((t) => t.title.toLowerCase().includes(q));
  }, [data, search]);

  // Three lanes; statuses collapse into them. Dropping a card applies the
  // lane's canonical status, which starts/stops the agent server-side.
  const byColumn = useMemo(() => {
    const map = new Map<string, Task[]>();
    KANBAN_COLUMNS.forEach((column) => map.set(column, []));
    tasks.forEach((task) => {
      map.get(kanbanColumnFor(task.status))?.push(task);
    });
    return map;
  }, [tasks]);

  const handleDrop = (status: TaskStatus) => (e: DragEvent) => {
    e.preventDefault();
    setDragOver(null);
    const taskId = e.dataTransfer.getData("text/task-id");
    const task = tasks.find((t) => t.id === taskId);
    if (task && kanbanColumnFor(task.status) !== kanbanColumnFor(status)) {
      updateTask.mutate({ id: taskId, status });
    }
  };

  return (
    <div className="flex h-full gap-5">
      <div className="flex min-w-0 flex-1 flex-col gap-4">
        <PageHeader
          title="Tasks"
          subtitle={
            <>
              {tasks.length} tasks · {data?.meta.completed_today ?? 0} completed today
            </>
          }
          actions={
            <Button onClick={() => setShowNewTask(true)} data-tour="new-task">
              <Plus size={14} /> New Task
            </Button>
          }
        />

        <div className="flex flex-wrap items-center gap-3">
          <div className="flex shrink-0 gap-0.5 rounded-lg bg-white/[0.03] p-0.5">
            <button
              onClick={() => setView("kanban")}
              className={cn(
                "mk-chip flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium mk-focus-ring",
                view === "kanban" ? "mk-chip-active" : "text-text-muted hover:text-text",
              )}
            >
              <LayoutGrid size={13} /> Board
            </button>
            <button
              onClick={() => setView("list")}
              className={cn(
                "mk-chip flex items-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium mk-focus-ring",
                view === "list" ? "mk-chip-active" : "text-text-muted hover:text-text",
              )}
            >
              <List size={13} /> List
            </button>
          </div>
          <SearchInput
            placeholder="Search tasks…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="min-w-0 w-full flex-1 sm:max-w-xs sm:flex-none sm:w-64"
          />
        </div>

        {isLoading ? (
          <SkeletonRows rows={5} />
        ) : tasks.length === 0 ? (
          <EmptyState
            icon={<CheckSquare size={24} />}
            title="No tasks found"
            description="Create your first task to get your agents working."
            action={
              <Button size="sm" onClick={() => setShowNewTask(true)}>
                <Plus size={13} /> New Task
              </Button>
            }
          />
        ) : view === "kanban" ? (
          <div className="grid min-h-0 min-w-0 flex-1 grid-cols-1 gap-3 sm:gap-4 md:grid-cols-3">
            {KANBAN_COLUMNS.map((status, columnIndex) => {
              const columnTasks = byColumn.get(status) ?? [];
              return (
                <div
                  key={status}
                  onDragOver={(e) => {
                    e.preventDefault();
                    setDragOver(status);
                  }}
                  onDragLeave={() => setDragOver(null)}
                  onDrop={handleDrop(status)}
                  style={{ animationDelay: `${columnIndex * 60}ms` }}
                  className={cn(
                    "mk-fade-up mk-kanban-col flex min-h-[220px] min-w-0 flex-col p-2 transition-shadow md:min-h-0 md:h-full",
                    dragOver === status &&
                      "bg-primary-muted/20 shadow-[inset_0_0_0_1px_rgba(124,92,255,0.35),0_0_18px_rgba(124,92,255,0.12)]",
                  )}
                >
                  <div className="flex items-center gap-2 px-2 pb-2 pt-1.5">
                    <span className={cn("mk-glow-dot h-2 w-2 rounded-full", columnAccent[status])} />
                    <span className="text-xs font-semibold text-text">
                      {KANBAN_COLUMN_LABELS[status]}
                    </span>
                    <span className="rounded-full bg-white/[0.05] px-1.5 py-px text-[10px] font-medium text-text-muted">
                      {columnTasks.length}
                    </span>
                  </div>
                  <div className="min-h-0 flex-1 space-y-2.5 overflow-y-auto p-1">
                    {columnTasks.map((task, taskIndex) => (
                      <KanbanCard
                        key={task.id}
                        task={task}
                        index={taskIndex}
                        flashed={flashedTaskIds.includes(task.id)}
                        onSelect={() => setSelectedId(task.id)}
                        onDragStart={(e) => e.dataTransfer.setData("text/task-id", task.id)}
                      />
                    ))}
                  </div>
                </div>
              );
            })}
          </div>
        ) : (
          <div className="mk-card min-w-0 overflow-x-auto">
            <table className="w-full min-w-[640px] text-left text-xs">
              <thead>
                <tr className="text-[11px] uppercase tracking-wide text-text-muted">
                  <th className="px-5 py-3 font-medium">Task</th>
                  <th className="px-3 py-3 font-medium">Project</th>
                  <th className="px-3 py-3 font-medium">Agent</th>
                  <th className="px-3 py-3 font-medium">Status</th>
                  <th className="px-3 py-3 font-medium">Priority</th>
                  <th className="px-5 py-3 font-medium">Due</th>
                </tr>
              </thead>
              <tbody>
                {tasks.map((task) => (
                  <tr
                    key={task.id}
                    onClick={() => setSelectedId(task.id)}
                    className={cn(
                      "mk-row cursor-pointer",
                      flashedTaskIds.includes(task.id) && "animate-pulse bg-primary/10",
                    )}
                  >
                    <td className="max-w-[280px] truncate px-5 py-3 font-medium text-text">
                      {task.title}
                    </td>
                    <td className="px-3 py-3 text-text-secondary">{task.project_name ?? "·"}</td>
                    <td className="px-3 py-3 text-text-secondary">
                      {task.assigned_agent_name ?? "Unassigned"}
                    </td>
                    <td className="px-3 py-3">
                      <TaskStatusBadge status={task.status} />
                    </td>
                    <td className="px-3 py-3">
                      <PriorityBadge priority={task.priority} />
                    </td>
                    <td className="px-5 py-3 text-text-muted">{formatRelative(task.due_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* TaskDetailPanel is rendered globally by AppShell (selectedTaskId). */}
      <NewTaskModal
        open={showNewTask}
        onOpenChange={setShowNewTask}
        defaultProjectId={activeProjectId ?? undefined}
      />

    </div>
  );
}
