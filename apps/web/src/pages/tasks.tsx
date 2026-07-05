import { useMemo, useState, type DragEvent } from "react";
import { CheckSquare, LayoutGrid, List, Plus } from "lucide-react";
import { KANBAN_COLUMNS, TASK_STATUS_LABELS, type TaskStatus } from "@mokaid/shared-types";
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
import { TaskDetailPanel } from "@/components/tasks/task-detail-panel";
import { NewTaskModal } from "@/components/modals/new-task-modal";
import { cn } from "@/lib/cn";
import { formatRelative } from "@/lib/format";

type ViewMode = "kanban" | "list";

const columnAccent: Record<string, string> = {
  to_do: "bg-text-muted",
  in_progress: "bg-info",
  in_review: "bg-primary",
  waiting: "bg-warning",
  completed: "bg-success",
};

function KanbanCard({
  task,
  onSelect,
  onDragStart,
}: {
  task: Task;
  onSelect: () => void;
  onDragStart: (e: DragEvent) => void;
}) {
  return (
    <button
      draggable
      onDragStart={onDragStart}
      onClick={onSelect}
      className="mk-card-raised w-full cursor-grab space-y-2.5 p-3 text-left transition-shadow hover:shadow-glow active:cursor-grabbing mk-focus-ring"
    >
      <div className="flex items-start justify-between gap-2">
        <p className="text-xs font-semibold leading-snug text-text">{task.title}</p>
        <PriorityBadge priority={task.priority} />
      </div>
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
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState<string | null>(null);
  const [showNewTask, setShowNewTask] = useState(false);

  const { data, isLoading } = useTasks();
  const updateTask = useUpdateTask();

  const tasks = useMemo(() => {
    const list = data?.data ?? [];
    if (!search) return list;
    const q = search.toLowerCase();
    return list.filter((t) => t.title.toLowerCase().includes(q));
  }, [data, search]);

  const byStatus = useMemo(() => {
    const map = new Map<string, Task[]>();
    KANBAN_COLUMNS.forEach((status) => map.set(status, []));
    tasks.forEach((task) => {
      const bucket = map.get(task.status);
      if (bucket) bucket.push(task);
      else map.get("to_do")?.push(task);
    });
    return map;
  }, [tasks]);

  const selectedTask = tasks.find((t) => t.id === selectedId) ?? null;

  const handleDrop = (status: TaskStatus) => (e: DragEvent) => {
    e.preventDefault();
    setDragOver(null);
    const taskId = e.dataTransfer.getData("text/task-id");
    const task = tasks.find((t) => t.id === taskId);
    if (task && task.status !== status) {
      updateTask.mutate({ id: taskId, status });
    }
  };

  return (
    <div className="flex h-full gap-5">
      <div className="flex min-w-0 flex-1 flex-col gap-4">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-bold text-text">Tasks</h1>
            <p className="text-xs text-text-muted">
              {tasks.length} tasks · {data?.meta.completed_today ?? 0} completed today
            </p>
          </div>
          <Button onClick={() => setShowNewTask(true)} data-tour="new-task">
            <Plus size={14} /> New Task
          </Button>
        </div>

        <div className="flex items-center gap-3">
          <div className="flex rounded-md border border-border bg-surface p-0.5">
            <button
              onClick={() => setView("kanban")}
              className={cn(
                "flex items-center gap-1.5 rounded px-3 py-1.5 text-xs font-medium transition-colors",
                view === "kanban" ? "bg-primary-muted text-primary-light" : "text-text-muted hover:text-text",
              )}
            >
              <LayoutGrid size={13} /> Board
            </button>
            <button
              onClick={() => setView("list")}
              className={cn(
                "flex items-center gap-1.5 rounded px-3 py-1.5 text-xs font-medium transition-colors",
                view === "list" ? "bg-primary-muted text-primary-light" : "text-text-muted hover:text-text",
              )}
            >
              <List size={13} /> List
            </button>
          </div>
          <SearchInput
            placeholder="Search tasks…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-64"
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
          <div className="flex min-h-0 flex-1 gap-4 overflow-x-auto pb-2">
            {KANBAN_COLUMNS.map((status) => {
              const columnTasks = byStatus.get(status) ?? [];
              return (
                <div
                  key={status}
                  onDragOver={(e) => {
                    e.preventDefault();
                    setDragOver(status);
                  }}
                  onDragLeave={() => setDragOver(null)}
                  onDrop={handleDrop(status)}
                  className={cn(
                    "flex w-64 shrink-0 flex-col rounded-lg border border-border bg-bg-deep/60 transition-colors",
                    dragOver === status && "border-primary/50 bg-primary-muted/20",
                  )}
                >
                  <div className="flex items-center gap-2 px-3 py-2.5">
                    <span className={cn("h-2 w-2 rounded-full", columnAccent[status])} />
                    <span className="text-xs font-semibold text-text">
                      {TASK_STATUS_LABELS[status]}
                    </span>
                    <span className="rounded-full bg-surface-overlay px-1.5 text-[10px] font-medium text-text-muted">
                      {columnTasks.length}
                    </span>
                  </div>
                  <div className="flex-1 space-y-2.5 overflow-y-auto px-2.5 pb-3">
                    {columnTasks.map((task) => (
                      <KanbanCard
                        key={task.id}
                        task={task}
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
          <div className="mk-card overflow-hidden">
            <table className="w-full text-left text-xs">
              <thead>
                <tr className="border-b border-border text-[11px] uppercase tracking-wide text-text-muted">
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
                    className="cursor-pointer border-b border-border/50 transition-colors last:border-0 hover:bg-surface-hover"
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

      <TaskDetailPanel task={selectedTask} onClose={() => setSelectedId(null)} />
      <NewTaskModal open={showNewTask} onOpenChange={setShowNewTask} />
    </div>
  );
}
