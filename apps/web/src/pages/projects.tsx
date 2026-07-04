import { useState } from "react";
import { FolderKanban, Plus } from "lucide-react";
import { useProjects } from "@/api/hooks";
import type { Project, ProjectActivity } from "@/api/types";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { Avatar } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { ProgressBar } from "@/components/ui/progress-bar";
import { DetailPanel } from "@/components/ui/detail-panel";
import { SkeletonRows } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/ui/empty-state";
import { PriorityBadge } from "@/components/ui/status";
import { cn } from "@/lib/cn";
import { formatDate, formatRelative } from "@/lib/format";

const statusTone: Record<string, "success" | "primary" | "warning" | "muted" | "info"> = {
  planning: "info",
  active: "success",
  in_review: "primary",
  on_hold: "warning",
  completed: "muted",
  archived: "muted",
};

const coverGradients: Record<string, string> = {
  meeting: "from-[#5936d1] to-[#8f72ff]",
  coding: "from-[#1d4ed8] to-[#60a5fa]",
  design: "from-[#be185d] to-[#f472b6]",
  whiteboard: "from-[#047857] to-[#34d399]",
  office: "from-[#b45309] to-[#fbbf24]",
};

function ProjectCard({ project, onSelect }: { project: Project; onSelect: () => void }) {
  return (
    <button
      onClick={onSelect}
      className="mk-card group overflow-hidden text-left transition-shadow hover:shadow-glow mk-focus-ring"
    >
      <div
        className={cn(
          "flex h-28 items-end bg-gradient-to-br p-3",
          coverGradients[project.cover_kind ?? "meeting"] ?? coverGradients.meeting,
        )}
      >
        <Badge tone={statusTone[project.status] ?? "default"} className="backdrop-blur">
          {project.status.replace("_", " ")}
        </Badge>
      </div>
      <div className="space-y-3 p-4">
        <div>
          <h3 className="text-sm font-semibold text-text group-hover:text-primary-light">
            {project.name}
          </h3>
          <p className="mt-0.5 line-clamp-2 text-[11px] leading-relaxed text-text-muted">
            {project.description}
          </p>
        </div>
        <div>
          <div className="mb-1 flex justify-between text-[11px] text-text-muted">
            <span>
              {project.completed_task_count}/{project.task_count} tasks
            </span>
            <span className="font-semibold text-text">{project.progress_percent}%</span>
          </div>
          <ProgressBar value={project.progress_percent} />
        </div>
        <div className="flex items-center justify-between">
          <div className="flex -space-x-1.5">
            {project.members.slice(0, 4).map((member) => (
              <Avatar
                key={member.member_id}
                name={member.full_name}
                size="xs"
                className="ring-2 ring-surface"
              />
            ))}
            {project.members.length > 4 && (
              <span className="flex h-6 w-6 items-center justify-center rounded-full bg-surface-overlay text-[9px] font-semibold text-text-muted ring-2 ring-surface">
                +{project.members.length - 4}
              </span>
            )}
          </div>
          <span className="text-[10px] text-text-muted">Due {formatDate(project.due_at)}</span>
        </div>
      </div>
    </button>
  );
}

export function ProjectsPage() {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const { data, isLoading } = useProjects();

  const projects = data?.data ?? [];
  const activity = (data?.meta.activity ?? []) as ProjectActivity[];
  const selected = projects.find((p) => p.id === selectedId) ?? null;

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-5">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-bold text-text">Projects</h1>
            <p className="text-xs text-text-muted">{projects.length} projects in this workspace</p>
          </div>
          <Button>
            <Plus size={14} /> New Project
          </Button>
        </div>

        {isLoading ? (
          <SkeletonRows rows={4} />
        ) : projects.length === 0 ? (
          <EmptyState
            icon={<FolderKanban size={24} />}
            title="No projects yet"
            description="Create a project to organize tasks, agents and files."
          />
        ) : (
          <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            {projects.map((project) => (
              <ProjectCard
                key={project.id}
                project={project}
                onSelect={() => setSelectedId(project.id)}
              />
            ))}
          </div>
        )}

        <Card>
          <CardHeader>
            <CardTitle>Recent Activity</CardTitle>
          </CardHeader>
          <CardBody className="space-y-3">
            {activity.slice(0, 8).map((event) => (
              <div key={event.id} className="flex items-center gap-3 text-xs">
                <Avatar name={event.actor_name} size="xs" isAi={event.actor_type === "agent"} />
                <p className="min-w-0 flex-1 truncate text-text-secondary">
                  <span className="font-semibold text-text">{event.actor_name ?? "System"}</span>{" "}
                  {event.event_type.replace("project.", "").replace("_", " ")}
                </p>
                <span className="shrink-0 text-[11px] text-text-muted">
                  {formatRelative(event.occurred_at)}
                </span>
              </div>
            ))}
            {activity.length === 0 && (
              <p className="py-4 text-center text-xs text-text-muted">No activity yet</p>
            )}
          </CardBody>
        </Card>
      </div>

      <DetailPanel open={selected != null} onClose={() => setSelectedId(null)} title="Project Details">
        {selected && (
          <div className="space-y-5 px-5 py-4">
            <div>
              <h3 className="text-sm font-bold text-text">{selected.name}</h3>
              <p className="mt-1 text-xs leading-relaxed text-text-secondary">
                {selected.description}
              </p>
            </div>

            <div className="flex items-center gap-2">
              <Badge tone={statusTone[selected.status] ?? "default"}>
                {selected.status.replace("_", " ")}
              </Badge>
              <PriorityBadge priority={selected.priority} />
            </div>

            <div>
              <div className="mb-1 flex justify-between text-[11px] text-text-muted">
                <span>Progress</span>
                <span className="font-semibold text-text">{selected.progress_percent}%</span>
              </div>
              <ProgressBar value={selected.progress_percent} />
            </div>

            <div className="grid grid-cols-2 gap-3 text-center">
              <div className="mk-card-raised p-3">
                <p className="text-lg font-bold text-text">{selected.task_count}</p>
                <p className="text-[11px] text-text-muted">Total tasks</p>
              </div>
              <div className="mk-card-raised p-3">
                <p className="text-lg font-bold text-success">{selected.completed_task_count}</p>
                <p className="text-[11px] text-text-muted">Completed</p>
              </div>
            </div>

            <div className="space-y-1.5 text-xs">
              <div className="flex justify-between">
                <span className="text-text-muted">Owner</span>
                <span className="text-text">{selected.owner_name ?? "—"}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">Start</span>
                <span className="text-text">{formatDate(selected.start_at)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">Due</span>
                <span className="text-text">{formatDate(selected.due_at)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">Agents assigned</span>
                <span className="text-text">{selected.agent_ids.length}</span>
              </div>
            </div>

            <div>
              <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                Team Members
              </p>
              <div className="space-y-2">
                {selected.members.map((member) => (
                  <div key={member.member_id} className="flex items-center gap-2.5">
                    <Avatar name={member.full_name} size="sm" />
                    <div className="min-w-0">
                      <p className="truncate text-xs font-medium text-text">{member.full_name}</p>
                      <p className="text-[10px] capitalize text-text-muted">{member.role}</p>
                    </div>
                  </div>
                ))}
                {selected.members.length === 0 && (
                  <p className="text-xs text-text-muted">No members assigned.</p>
                )}
              </div>
            </div>
          </div>
        )}
      </DetailPanel>
    </div>
  );
}
