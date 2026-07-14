import { useEffect, useMemo, useState } from "react";
import { AlertTriangle, Trash2 } from "lucide-react";
import type { Project } from "@/api/types";
import { useDeleteProject, useUpdateProject } from "@/api/hooks";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { DetailPanel } from "@/components/ui/detail-panel";
import { ProgressBar } from "@/components/ui/progress-bar";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { PriorityBadge } from "@/components/ui/status";
import { getProjectCover } from "@/lib/project-covers";
import { cn } from "@/lib/cn";
import { formatDate } from "@/lib/format";
import { toast } from "@/stores/toast-store";
import { useAuthStore } from "@/stores/auth-store";
import { useProjectStore } from "@/stores/project-store";

const statusDot: Record<string, string> = {
  planning: "bg-info",
  active: "bg-success",
  in_review: "bg-primary",
  on_hold: "bg-warning",
  completed: "bg-text-muted",
  archived: "bg-text-disabled",
};

const statusOptions = [
  { value: "planning", label: "Planning" },
  { value: "active", label: "Active" },
  { value: "in_review", label: "In review" },
  { value: "on_hold", label: "On hold" },
  { value: "completed", label: "Completed" },
];

const priorityOptions = [
  { value: "low", label: "Low" },
  { value: "medium", label: "Medium" },
  { value: "high", label: "High" },
  { value: "urgent", label: "Urgent" },
];

function StatusLabel({ status }: { status: string }) {
  return (
    <span className="inline-flex items-center gap-1.5 text-[10px] capitalize text-text-muted">
      <span className={cn("h-1.5 w-1.5 rounded-full", statusDot[status] ?? "bg-text-muted")} />
      {status.replace("_", " ")}
    </span>
  );
}

function toDateInput(iso: string | null): string {
  if (!iso) return "";
  return iso.slice(0, 10);
}

export function ProjectDetailPanel({
  project,
  onClose,
}: {
  project: Project | null;
  onClose: () => void;
}) {
  const updateProject = useUpdateProject();
  const deleteProject = useDeleteProject();
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const setActiveProject = useProjectStore((s) => s.setActiveProject);

  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [status, setStatus] = useState("active");
  const [priority, setPriority] = useState("medium");
  const [dueAt, setDueAt] = useState("");
  const [deleteConfirm, setDeleteConfirm] = useState("");

  useEffect(() => {
    if (!project) return;
    setName(project.name);
    setDescription(project.description ?? "");
    setStatus(project.status);
    setPriority(project.priority);
    setDueAt(toDateInput(project.due_at));
    setDeleteConfirm("");
  }, [project?.id, project?.name, project?.description, project?.status, project?.priority, project?.due_at]);

  const expectedDeletePhrase = project ? `delete ${project.name}` : "";
  const canDelete = useMemo(
    () => deleteConfirm === expectedDeletePhrase,
    [deleteConfirm, expectedDeletePhrase],
  );

  const saveField = (body: Partial<Project>) => {
    if (!project) return;
    updateProject.mutate(
      { id: project.id, ...body },
      {
        onError: () =>
          toast({
            tone: "error",
            title: "Could not update project",
            description: "Check your permissions and try again.",
          }),
      },
    );
  };

  const saveName = () => {
    if (!project) return;
    const trimmed = name.trim();
    if (!trimmed) {
      setName(project.name);
      return;
    }
    if (trimmed !== project.name) saveField({ name: trimmed });
  };

  const saveDescription = () => {
    if (!project) return;
    const next = description.trim();
    const current = project.description ?? "";
    if (next !== current) saveField({ description: next || null });
  };

  const saveDueAt = () => {
    if (!project) return;
    const next = dueAt ? new Date(`${dueAt}T00:00:00`).toISOString() : null;
    const current = project.due_at ? toDateInput(project.due_at) : "";
    if (dueAt !== current) saveField({ due_at: next });
  };

  const handleDelete = () => {
    if (!project || !canDelete) return;
    deleteProject.mutate(project.id, {
      onSuccess: () => {
        if (workspaceId) {
          const active = useProjectStore.getState().activeProjectByWorkspace[workspaceId];
          if (active === project.id) setActiveProject(workspaceId, null);
        }
        toast({
          tone: "success",
          title: "Project deleted",
          description: `"${project.name}" and its tasks were permanently removed.`,
        });
        onClose();
      },
      onError: () =>
        toast({
          tone: "error",
          title: "Could not delete project",
          description: "Only owners and admins can delete projects.",
        }),
    });
  };

  return (
    <DetailPanel open={project != null} onClose={onClose} title="Project Details">
      {project && (
        <div className="space-y-6 px-5 py-4">
          <div>
            <div className="mb-2 flex items-center gap-2">
              {(() => {
                const { Icon } = getProjectCover(project.cover_kind);
                return <Icon size={14} className="text-text-muted" strokeWidth={1.5} />;
              })()}
              <StatusLabel status={project.status} />
              <PriorityBadge priority={project.priority} />
            </div>
          </div>

          <label className="block space-y-1.5">
            <span className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
              Name
            </span>
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              onBlur={saveName}
              onKeyDown={(e) => {
                if (e.key === "Enter") (e.target as HTMLInputElement).blur();
              }}
              disabled={updateProject.isPending}
              className="mk-input h-9"
              aria-label="Project name"
            />
          </label>

          <label className="block space-y-1.5">
            <span className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
              Description
            </span>
            <Textarea
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              onBlur={saveDescription}
              disabled={updateProject.isPending}
              placeholder="What is this project about?"
              rows={3}
            />
          </label>

          <div className="grid grid-cols-2 gap-3">
            <label className="block space-y-1.5">
              <span className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                Status
              </span>
              <Select
                value={status}
                onValueChange={(value) => {
                  setStatus(value);
                  if (value !== project.status) saveField({ status: value as Project["status"] });
                }}
                options={statusOptions}
                disabled={updateProject.isPending}
              />
            </label>
            <label className="block space-y-1.5">
              <span className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                Priority
              </span>
              <Select
                value={priority}
                onValueChange={(value) => {
                  setPriority(value);
                  if (value !== project.priority) {
                    saveField({ priority: value as Project["priority"] });
                  }
                }}
                options={priorityOptions}
                disabled={updateProject.isPending}
              />
            </label>
          </div>

          <label className="block space-y-1.5">
            <span className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
              Due date
            </span>
            <input
              type="date"
              value={dueAt}
              onChange={(e) => setDueAt(e.target.value)}
              onBlur={saveDueAt}
              disabled={updateProject.isPending}
              className="mk-input h-9"
            />
          </label>

          <div>
            <div className="mb-2 flex justify-between text-[11px] text-text-muted">
              <span>Progress</span>
              <span className="tabular-nums text-text">{project.progress_percent}%</span>
            </div>
            <ProgressBar value={project.progress_percent} tone="primary" size="xs" />
          </div>

          <div className="flex gap-6 text-xs">
            <div>
              <p className="text-lg font-medium tabular-nums text-text">{project.task_count}</p>
              <p className="text-[10px] text-text-muted">Tasks</p>
            </div>
            <div>
              <p className="text-lg font-medium tabular-nums text-text">
                {project.completed_task_count}
              </p>
              <p className="text-[10px] text-text-muted">Done</p>
            </div>
            <div>
              <p className="text-lg font-medium tabular-nums text-text">
                {project.agent_ids.length}
              </p>
              <p className="text-[10px] text-text-muted">Agents</p>
            </div>
          </div>

          <div className="space-y-2 text-xs">
            <div className="flex justify-between gap-4">
              <span className="text-text-muted">Owner</span>
              <span className="text-text">{project.owner_name ?? "None"}</span>
            </div>
            <div className="flex justify-between gap-4">
              <span className="text-text-muted">Start</span>
              <span className="tabular-nums text-text">{formatDate(project.start_at)}</span>
            </div>
            <div className="flex justify-between gap-4">
              <span className="text-text-muted">Due</span>
              <span className="tabular-nums text-text">{formatDate(project.due_at)}</span>
            </div>
          </div>

          {project.members.length > 0 && (
            <div>
              <p className="mb-2.5 text-[10px] font-medium uppercase tracking-wider text-text-muted">
                Team
              </p>
              <div className="space-y-2">
                {project.members.map((member) => (
                  <div key={member.member_id} className="flex items-center gap-2.5">
                    <Avatar name={member.full_name} size="sm" />
                    <div className="min-w-0">
                      <p className="truncate text-xs text-text">{member.full_name}</p>
                      <p className="text-[10px] capitalize text-text-muted">{member.role}</p>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          <div className="space-y-3 rounded-xl border border-danger/25 bg-danger/5 p-4">
            <div className="flex items-start gap-2">
              <AlertTriangle size={14} className="mt-0.5 shrink-0 text-danger" />
              <div className="space-y-1">
                <p className="text-xs font-semibold text-danger">Danger zone</p>
                <p className="text-[11px] leading-relaxed text-text-secondary">
                  Deleting this project is permanent. It will also permanently delete all{" "}
                  <span className="font-semibold text-text">
                    {project.task_count} associated task
                    {project.task_count === 1 ? "" : "s"}
                  </span>
                  , including their comments, attachments and AI runs. This cannot be undone.
                </p>
              </div>
            </div>

            <label className="block space-y-1.5">
              <span className="text-[11px] text-text-muted">
                Type{" "}
                <code className="rounded bg-surface-raised px-1 py-0.5 text-[10px] text-text">
                  {expectedDeletePhrase}
                </code>{" "}
                to confirm
              </span>
              <input
                value={deleteConfirm}
                onChange={(e) => setDeleteConfirm(e.target.value)}
                placeholder={expectedDeletePhrase}
                className="mk-input h-9 border-danger/30"
                aria-label="Confirm project deletion"
                autoComplete="off"
              />
            </label>

            <Button
              variant="danger"
              size="sm"
              className="w-full"
              disabled={!canDelete || deleteProject.isPending}
              loading={deleteProject.isPending}
              onClick={handleDelete}
            >
              <Trash2 size={13} />
              Delete project and all tasks
            </Button>
          </div>
        </div>
      )}
    </DetailPanel>
  );
}
