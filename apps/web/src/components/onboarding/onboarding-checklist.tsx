import { useMemo, useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import {
  Bot,
  CheckCircle2,
  ChevronRight,
  Circle,
  ClipboardList,
  FolderKanban,
  ListChecks,
  Plug,
  Sparkles,
  UserPlus,
  X,
} from "lucide-react";
import {
  useAgents,
  useIntegrations,
  useMembers,
  useOnboardingSettings,
  useProjects,
  useTasks,
  useUpdateOnboarding,
} from "@/api/hooks";
import { useOnboardingStore } from "@/stores/onboarding-store";
import { cn } from "@/lib/cn";

interface ChecklistItem {
  key: string;
  label: string;
  description: string;
  icon: React.ReactNode;
  done: boolean;
  action: () => void;
}

function ProgressRing({ value, total }: { value: number; total: number }) {
  const radius = 15;
  const circumference = 2 * Math.PI * radius;
  const progress = total > 0 ? value / total : 0;
  return (
    <svg width="38" height="38" viewBox="0 0 38 38" className="-rotate-90">
      <circle
        cx="19"
        cy="19"
        r={radius}
        fill="none"
        strokeWidth="3"
        className="stroke-surface-raised"
      />
      <circle
        cx="19"
        cy="19"
        r={radius}
        fill="none"
        strokeWidth="3"
        strokeLinecap="round"
        strokeDasharray={circumference}
        strokeDashoffset={circumference * (1 - progress)}
        className="stroke-primary transition-[stroke-dashoffset] duration-700"
      />
    </svg>
  );
}

export function OnboardingChecklist({ collapsed = false }: { collapsed?: boolean }) {
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const startTour = useOnboardingStore((s) => s.startTour);

  const { onboarding, loaded } = useOnboardingSettings();
  const updateOnboarding = useUpdateOnboarding();

  const { data: agentsData } = useAgents();
  const { data: projectsData } = useProjects();
  const { data: tasksData } = useTasks();
  const { data: membersData } = useMembers();
  const { data: integrationsData } = useIntegrations();

  const items: ChecklistItem[] = useMemo(() => {
    const agents = agentsData?.data ?? [];
    const projects = projectsData?.data ?? [];
    const tasks = tasksData?.data ?? [];
    const members = membersData?.data ?? [];
    const pendingInvites = membersData?.meta.pending_invites ?? [];
    const connections = (integrationsData?.data.connections ?? []).filter(
      (c) => c.status === "connected",
    );

    return [
      {
        key: "agent",
        label: "Create your first agent",
        description: "Hire an AI teammate",
        icon: <Bot size={14} />,
        done: agents.length > 0,
        action: () => navigate({ to: "/agents" }),
      },
      {
        key: "project",
        label: "Create a project",
        description: "Organize your work",
        icon: <FolderKanban size={14} />,
        done: projects.length > 0,
        action: () => navigate({ to: "/projects" }),
      },
      {
        key: "task",
        label: "Assign your first task",
        description: "Brief an agent in plain language",
        icon: <ClipboardList size={14} />,
        done: tasks.length > 0,
        action: () => navigate({ to: "/tasks" }),
      },
      {
        key: "integration",
        label: "Connect a tool",
        description: "Slack, GitHub, Google Drive…",
        icon: <Plug size={14} />,
        done: connections.length > 0,
        action: () => navigate({ to: "/integrations" }),
      },
      {
        key: "invite",
        label: "Invite a teammate",
        description: "Work together with your team",
        icon: <UserPlus size={14} />,
        done: members.length > 1 || pendingInvites.length > 0,
        action: () => navigate({ to: "/members" }),
      },
      {
        key: "tour",
        label: "Take the product tour",
        description: "60-second guided walkthrough",
        icon: <Sparkles size={14} />,
        done: onboarding.tour_done === true,
        action: () => {
          setOpen(false);
          startTour();
        },
      },
    ];
  }, [agentsData, projectsData, tasksData, membersData, integrationsData, onboarding.tour_done, navigate, startTour]);

  const doneCount = items.filter((i) => i.done).length;
  const allDone = doneCount === items.length;

  // Hidden until wizard is done; hidden forever once dismissed or complete.
  if (!loaded || !onboarding.wizard_done || onboarding.checklist_dismissed || allDone) {
    return null;
  }

  const dismiss = () => {
    updateOnboarding.mutate({ checklist_dismissed: true });
    setOpen(false);
  };

  return (
    <div className="relative">
      {open && (
        <div
          className={cn(
            "absolute bottom-full z-40 mb-2 w-[320px] rounded-2xl bg-surface p-4 shadow-[0_12px_48px_rgba(0,0,0,0.35)] mk-fade-up",
            collapsed ? "left-0" : "left-0 right-0 w-auto min-w-[240px]",
          )}
        >
          <div className="mb-3 flex items-start justify-between">
            <div>
              <h3 className="text-sm font-bold text-text">Getting started</h3>
              <p className="text-[11px] text-text-muted">
                {doneCount} of {items.length} completed
              </p>
            </div>
            <div className="flex items-center gap-1">
              <button
                onClick={dismiss}
                title="Dismiss checklist"
                className="rounded-lg p-1.5 text-text-muted transition-colors hover:bg-surface-hover hover:text-text"
              >
                <X size={13} />
              </button>
            </div>
          </div>

          <div className="mb-3 h-1.5 overflow-hidden rounded-full bg-surface-raised">
            <div
              className="h-full rounded-full bg-gradient-to-r from-primary to-primary/70 transition-all duration-700"
              style={{ width: `${(doneCount / items.length) * 100}%` }}
            />
          </div>

          <div className="space-y-1">
            {items.map((item) => (
              <button
                key={item.key}
                onClick={() => {
                  if (!item.done) item.action();
                }}
                disabled={item.done}
                className={cn(
                  "group flex w-full items-center gap-2.5 rounded-xl px-2.5 py-2 text-left transition-colors",
                  item.done ? "opacity-60" : "hover:bg-surface-hover",
                )}
              >
                {item.done ? (
                  <CheckCircle2 size={16} className="shrink-0 text-success" />
                ) : (
                  <Circle size={16} className="shrink-0 text-text-muted/40" />
                )}
                <span className="min-w-0 flex-1">
                  <span
                    className={cn(
                      "block text-xs font-medium",
                      item.done ? "text-text-muted line-through" : "text-text",
                    )}
                  >
                    {item.label}
                  </span>
                  {!item.done && (
                    <span className="block text-[10px] text-text-muted">{item.description}</span>
                  )}
                </span>
                {!item.done && (
                  <ChevronRight
                    size={13}
                    className="shrink-0 text-text-muted opacity-0 transition-opacity group-hover:opacity-100"
                  />
                )}
              </button>
            ))}
          </div>
        </div>
      )}

      <button
        onClick={() => setOpen((v) => !v)}
        title={collapsed ? "Getting started" : undefined}
        className={cn(
          "flex w-full items-center gap-2.5 rounded-md px-3 py-2 text-left transition-colors hover:bg-surface-hover",
          open && "bg-surface-hover",
          collapsed && "justify-center px-2",
        )}
      >
        <span className="relative flex shrink-0 items-center justify-center">
          <ProgressRing value={doneCount} total={items.length} />
          <ListChecks size={14} className="absolute text-primary-light" />
        </span>
        {!collapsed && (
          <span className="min-w-0">
            <span className="block text-[13px] font-semibold text-text">Getting started</span>
            <span className="block text-[11px] text-text-muted">
              {doneCount}/{items.length} done
            </span>
          </span>
        )}
      </button>
    </div>
  );
}
