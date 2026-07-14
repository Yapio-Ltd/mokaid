import { useState } from "react";
import { FolderKanban, Plus } from "lucide-react";
import { useProjects } from "@/api/hooks";
import type { Project, ProjectActivity } from "@/api/types";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { ProgressBar } from "@/components/ui/progress-bar";
import { SkeletonRows } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/ui/empty-state";
import { NewProjectModal } from "@/components/modals/new-project-modal";
import { ProjectDetailPanel } from "@/components/projects/project-detail-panel";
import { getProjectCover } from "@/lib/project-covers";
import { cn } from "@/lib/cn";
import { formatDate, formatRelative } from "@/lib/format";

const statusDot: Record<string, string> = {
  planning: "bg-info",
  active: "bg-success",
  in_review: "bg-primary",
  on_hold: "bg-warning",
  completed: "bg-text-muted",
  archived: "bg-text-disabled",
};

function StatusLabel({ status }: { status: string }) {
  return (
    <span className="inline-flex items-center gap-1.5 text-[10px] capitalize text-text-muted">
      <span className={cn("h-1.5 w-1.5 rounded-full", statusDot[status] ?? "bg-text-muted")} />
      {status.replace("_", " ")}
    </span>
  );
}

function ProjectCard({ project, onSelect }: { project: Project; onSelect: () => void }) {
  const cover = getProjectCover(project.cover_kind);
  const { Icon } = cover;

  return (
    <button
      onClick={onSelect}
      className="group flex flex-col rounded-xl bg-surface p-4 text-left transition-colors duration-200 hover:bg-surface-raised mk-focus-ring"
    >
      <div className="mb-3 flex items-center justify-between gap-2">
        <Icon size={15} className="shrink-0 text-text-muted transition-colors group-hover:text-primary-light" strokeWidth={1.5} />
        <StatusLabel status={project.status} />
      </div>

      <h3 className="text-[13px] font-medium leading-snug text-text">{project.name}</h3>
      {project.description && (
        <p className="mt-1 line-clamp-2 text-[11px] leading-relaxed text-text-muted">
          {project.description}
        </p>
      )}

      <div className="mt-4 space-y-1.5">
        <ProgressBar value={project.progress_percent} tone="primary" size="xs" />
        <div className="flex items-center justify-between text-[10px] text-text-muted">
          <span>
            {project.completed_task_count}/{project.task_count} tasks
          </span>
          <span className="tabular-nums">{project.progress_percent}%</span>
        </div>
      </div>

      <div className="mt-3 flex items-center justify-between">
        <div className="flex -space-x-1">
          {project.members.slice(0, 3).map((member) => (
            <Avatar
              key={member.member_id}
              name={member.full_name}
              size="xs"
              className="ring-1 ring-surface"
            />
          ))}
          {project.members.length > 3 && (
            <span className="flex h-5 w-5 items-center justify-center rounded-full bg-surface-overlay text-[8px] font-medium text-text-muted ring-1 ring-surface">
              +{project.members.length - 3}
            </span>
          )}
        </div>
        <span className="text-[10px] text-text-muted">{formatDate(project.due_at)}</span>
      </div>
    </button>
  );
}

function ActivityRow({ event }: { event: ProjectActivity }) {
  return (
    <div className="flex items-center gap-3 rounded-lg px-2 py-2 transition-colors hover:bg-surface">
      <Avatar name={event.actor_name} size="xs" isAi={event.actor_type === "agent"} />
      <p className="min-w-0 flex-1 truncate text-[11px] text-text-secondary">
        <span className="text-text">{event.actor_name ?? "System"}</span>{" "}
        {event.event_type.replace("project.", "").replace("_", " ")}
      </p>
      <span className="shrink-0 text-[10px] tabular-nums text-text-muted">
        {formatRelative(event.occurred_at)}
      </span>
    </div>
  );
}

export function ProjectsPage() {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [showNewProject, setShowNewProject] = useState(false);
  const { data, isLoading } = useProjects();

  const projects = data?.data ?? [];
  const activity = (data?.meta.activity ?? []) as ProjectActivity[];
  const selected = projects.find((p) => p.id === selectedId) ?? null;

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-8">
        <div className="flex items-end justify-between gap-3">
          <div>
            <h1 className="text-lg font-semibold tracking-tight text-text">Projects</h1>
            <p className="mt-0.5 text-[11px] text-text-muted">
              {projects.length} in this workspace
            </p>
          </div>
          <Button size="sm" onClick={() => setShowNewProject(true)} data-tour="new-project">
            <Plus size={13} /> New
          </Button>
        </div>

        {isLoading ? (
          <SkeletonRows rows={4} />
        ) : projects.length === 0 ? (
          <EmptyState
            icon={<FolderKanban size={24} />}
            title="No projects yet"
            description="Create a project to organize tasks, agents and files."
            action={
              <Button size="sm" onClick={() => setShowNewProject(true)}>
                <Plus size={13} /> New Project
              </Button>
            }
          />
        ) : (
          <div className="grid gap-2.5 sm:grid-cols-2 xl:grid-cols-3">
            {projects.map((project) => (
              <ProjectCard
                key={project.id}
                project={project}
                onSelect={() => setSelectedId(project.id)}
              />
            ))}
          </div>
        )}

        {activity.length > 0 && (
          <section className="space-y-2">
            <h2 className="text-[11px] font-medium uppercase tracking-wider text-text-muted">
              Recent activity
            </h2>
            <div className="space-y-0.5">
              {activity.slice(0, 8).map((event) => (
                <ActivityRow key={event.id} event={event} />
              ))}
            </div>
          </section>
        )}
      </div>

      <ProjectDetailPanel project={selected} onClose={() => setSelectedId(null)} />
      <NewProjectModal
        open={showNewProject}
        onOpenChange={setShowNewProject}
        onCreated={(id) => setSelectedId(id)}
      />
    </div>
  );
}
