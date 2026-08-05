import { useState } from "react";
import { FolderKanban, Plus } from "lucide-react";
import { useProjects } from "@/api/hooks";
import type { Project } from "@/api/types";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { ProgressBar } from "@/components/ui/progress-bar";
import { SkeletonRows } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/ui/empty-state";
import { NewProjectModal } from "@/components/modals/new-project-modal";
import { PageHeader } from "@/components/ui/page-header";
import { ProjectDetailPanel } from "@/components/projects/project-detail-panel";
import { getProjectCover } from "@/lib/project-covers";
import { cn } from "@/lib/cn";
import { formatDate } from "@/lib/format";

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
      <span
        className={cn(
          "h-1.5 w-1.5 rounded-full",
          statusDot[status] ?? "bg-text-muted",
          status === "active" && "mk-glow-dot text-success",
        )}
      />
      {status.replace("_", " ")}
    </span>
  );
}

function ProjectCard({
  project,
  index,
  onSelect,
}: {
  project: Project;
  index: number;
  onSelect: () => void;
}) {
  const cover = getProjectCover(project.cover_kind);
  const { Icon } = cover;

  return (
    <button
      onClick={onSelect}
      className="group mk-tile mk-fade-up flex flex-col rounded-xl p-4 text-left mk-focus-ring"
      style={{ animationDelay: `${Math.min(index, 10) * 30}ms` }}
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
        <ProgressBar
          value={project.progress_percent}
          tone="primary"
          size="xs"
          className="[&>div]:shadow-[0_0_8px_rgba(124,92,255,.5)]"
        />
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

export function ProjectsPage() {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [showNewProject, setShowNewProject] = useState(false);
  const { data, isLoading } = useProjects();

  const projects = data?.data ?? [];
  const selected = projects.find((p) => p.id === selectedId) ?? null;

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-8">
        <PageHeader
          title="Projects"
          subtitle={<>{projects.length} in this workspace</>}
          actions={
            <Button size="sm" onClick={() => setShowNewProject(true)} data-tour="new-project">
              <Plus size={13} /> New
            </Button>
          }
        />

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
            {projects.map((project, index) => (
              <ProjectCard
                key={project.id}
                project={project}
                index={index}
                onSelect={() => setSelectedId(project.id)}
              />
            ))}
          </div>
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
