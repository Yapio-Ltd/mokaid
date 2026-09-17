import { useEffect } from "react";
import * as Tabs from "@radix-ui/react-tabs";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { Link } from "@tanstack/react-router";
import { ArrowUpRight, Check, ChevronDown, MessageSquare, Pencil, Plus, X } from "lucide-react";
import type { Agent } from "@/api/types";
import {
  useAgentMcpGrants,
  useAgentProgression,
  useMcpHub,
  useTasks,
  useUpdateAgent,
} from "@/api/hooks";
import { WorkforceAgentPortrait } from "@/components/agents/workforce-agent-portrait";
import {
  PerformanceScoreGauge,
  TaskCompletionBars,
  TaskProgressBars,
} from "@/components/agents/workforce-metrics";
import { WorkforceAgentActions } from "@/components/agents/workforce-agent-actions";
import { MemoriesSection } from "@/components/agents/memories-section";
import { McpLogo } from "@/components/mcp/mcp-logo";
import { TaskStatusBadge } from "@/components/ui/status";
import { formatDate, formatNumber, formatRelative } from "@/lib/format";
import { useAuthStore } from "@/stores/auth-store";
import { useChatStore } from "@/stores/chat-store";
import { useUiStore } from "@/stores/ui-store";
import { toast } from "@/stores/toast-store";
import "./workforce-agent-panel.css";

function AgentAvailability({ agent }: { agent: Agent }) {
  const updateAgent = useUpdateAgent();
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          className="wf-detail-availability"
          aria-label={`Availability for ${agent.display_name}`}
        >
          <span className="wf-detail-status" data-status={agent.status}>
            <i aria-hidden="true" />
          </span>
          {agent.status.charAt(0).toUpperCase() + agent.status.slice(1)}
          <ChevronDown size={14} />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content className="wf-menu" align="end" sideOffset={8}>
          <DropdownMenu.Label className="wf-menu-label">Agent availability</DropdownMenu.Label>
          <DropdownMenu.CheckboxItem
            checked={agent.ai_enabled}
            disabled={agent.kind === "human_linked" || updateAgent.isPending}
            onCheckedChange={(enabled) =>
              updateAgent.mutate(
                { id: agent.id, ai_enabled: enabled },
                {
                  onError: () =>
                    toast({
                      tone: "error",
                      title: "Could not update agent",
                      description: "Check your permissions and try again.",
                    }),
                },
              )
            }
          >
            <span className="wf-menu-check">
              <DropdownMenu.ItemIndicator>
                <Check size={14} />
              </DropdownMenu.ItemIndicator>
            </span>
            AI assistance enabled
          </DropdownMenu.CheckboxItem>
          <DropdownMenu.Item asChild>
            <Link to="/agents/$agentId" params={{ agentId: agent.id }}>
              Manage agent settings <ArrowUpRight size={13} />
            </Link>
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

function AgentIntegrations({ agentId }: { agentId: string }) {
  const hub = useMcpHub();
  const grants = useAgentMcpGrants(agentId);
  const grantedIds = new Set(
    (grants.data?.data ?? [])
      .filter((grant) => grant.granted)
      .map((grant) => grant.installation_id),
  );
  const installations = (hub.data?.data.installations ?? []).filter((installation) =>
    grantedIds.has(installation.id),
  );

  return (
    <section className="wf-detail-section">
      <div className="wf-detail-section-heading">
        <h3>Integrations</h3>
        <Link to="/agents/$agentId" params={{ agentId }} className="wf-detail-text-link">
          Manage <ArrowUpRight size={12} />
        </Link>
      </div>
      {hub.isError || grants.isError ? (
        <p className="wf-detail-muted" role="status">
          Integrations could not be loaded.
        </p>
      ) : hub.isLoading || grants.isLoading ? (
        <p className="wf-detail-muted" role="status">
          Loading integrations…
        </p>
      ) : installations.length === 0 ? (
        <p className="wf-detail-empty">No integrations granted to this agent yet.</p>
      ) : (
        <div className="wf-detail-integrations">
          {installations.map((installation) => (
            <Link key={installation.id} to="/integrations" className="wf-detail-integration">
              <McpLogo
                logoUrl={installation.logo_url}
                logoSlug={installation.logo_slug}
                name={installation.server_name}
                category={installation.category}
                size="sm"
              />
              <span>
                <span className="wf-detail-integration-name">{installation.server_name}</span>
                <span
                  className="wf-detail-integration-state"
                  data-connected={installation.status === "connected"}
                >
                  <i aria-hidden="true" />
                  {installation.status.charAt(0).toUpperCase() + installation.status.slice(1)}
                </span>
              </span>
            </Link>
          ))}
        </div>
      )}
    </section>
  );
}

function Skills({ agent, expanded = false }: { agent: Agent; expanded?: boolean }) {
  return (
    <section className="wf-detail-section">
      <h3>Skills</h3>
      {agent.skills.length > 0 ? (
        expanded ? (
          <div className="wf-detail-skill-levels">
            {agent.skills.map((skill) => (
              <div key={skill.name}>
                <div className="wf-detail-skill-label">
                  <span>{skill.name}</span>
                  <span>{skill.level ?? 0}%</span>
                </div>
                <progress
                  className="wf-detail-progress"
                  max={100}
                  value={skill.level ?? 0}
                  aria-label={`${skill.name} proficiency`}
                />
              </div>
            ))}
          </div>
        ) : (
          <div className="wf-detail-skills">
            {agent.skills.map((skill) => (
              <span key={skill.name}>{skill.name}</span>
            ))}
            <Link to="/agents/$agentId" params={{ agentId: agent.id }}>
              <Plus size={12} /> Manage skills
            </Link>
          </div>
        )
      ) : (
        <p className="wf-detail-empty">
          No skills added yet. Skills develop as your agent completes missions.
        </p>
      )}
    </section>
  );
}

/** The Agents workspace inspector. All metrics and access badges reflect persisted agent data. */
export function WorkforceAgentPanel({ agent, onClose }: { agent: Agent; onClose: () => void }) {
  const tasks = useTasks({ agent_id: agent.id });
  const progression = useAgentProgression(agent.id);
  const workspace = useAuthStore((state) =>
    state.workspaces.find((item) => item.id === agent.workspace_id),
  );
  const openChat = useChatStore((state) => state.openChat);
  const selectTask = useUiStore((state) => state.selectTask);
  const agentTasks = (tasks.data?.data ?? []).filter((task) => task.assigned_agent_id === agent.id);
  const activeTasks = agentTasks.filter(
    (task) => task.status !== "completed" && task.status !== "canceled",
  );
  const score = progression.data?.data.performance_score ?? agent.performance_score;
  const completed = progression.data?.data.missions_completed ?? agent.missions_completed;
  const statusLabel = agent.status.charAt(0).toUpperCase() + agent.status.slice(1);

  useEffect(() => {
    function handleEscape(event: KeyboardEvent) {
      // Allow an open menu, dialog, or task inspector to handle Escape first.
      if (
        event.key === "Escape" &&
        !event.defaultPrevented &&
        !(
          event.target instanceof window.Element &&
          event.target.closest('.wf-sidebar, [role="menu"], [role="dialog"]')
        ) &&
        !useUiStore.getState().selectedTaskId
      )
        onClose();
    }
    document.addEventListener("keydown", handleEscape);
    return () => document.removeEventListener("keydown", handleEscape);
  }, [onClose]);

  return (
    <aside
      className="wf-detail-panel"
      tabIndex={-1}
      aria-label={`${agent.display_name} agent details`}
    >
      <header className="wf-detail-header">
        <WorkforceAgentPortrait agent={agent} size="detail" className="wf-detail-avatar" />
        <div className="wf-detail-identity">
          <div className="wf-detail-name-row">
            <h2>{agent.display_name}</h2>
            <span className="wf-detail-status" data-status={agent.status}>
              <i aria-hidden="true" />
              {statusLabel}
            </span>
          </div>
          <p>
            {agent.role_title ??
              (agent.kind === "human_linked" ? "Human-linked agent" : "AI Agent")}
          </p>
        </div>
        <div className="wf-detail-controls">
          <AgentAvailability agent={agent} />
          <WorkforceAgentActions agent={agent} />
          <button
            type="button"
            className="wf-detail-close"
            onClick={onClose}
            aria-label="Close agent details"
          >
            <X size={17} />
          </button>
        </div>
      </header>

      <Tabs.Root key={agent.id} defaultValue="overview" className="wf-detail-tabs">
        <Tabs.List className="wf-detail-tab-list" aria-label="Agent details">
          {["Overview", "Tasks", "Skills", "Knowledge", "Settings"].map((tab) => (
            <Tabs.Trigger key={tab} value={tab.toLowerCase()} className="wf-detail-tab">
              {tab}
            </Tabs.Trigger>
          ))}
        </Tabs.List>
        <div className="wf-detail-scroll">
          <Tabs.Content value="overview" className="wf-detail-content">
            <div className="wf-detail-stats">
              <div className="wf-detail-stat" data-tone="purple">
                <strong>{score == null ? "—" : `${Math.round(score)}%`}</strong>
                <span>Performance</span>
                <PerformanceScoreGauge
                  score={score}
                  color="#a17bff"
                  className="wf-detail-mini-chart"
                />
              </div>
              <div className="wf-detail-stat" data-tone="blue">
                <strong>{tasks.data ? formatNumber(activeTasks.length) : "—"}</strong>
                <span>Active tasks</span>
                <TaskProgressBars
                  tasks={tasks.data ? activeTasks : undefined}
                  color="#847abf"
                  className="wf-detail-mini-chart"
                />
              </div>
              <div className="wf-detail-stat" data-tone="purple">
                <strong>{completed == null ? "—" : formatNumber(completed)}</strong>
                <span>Missions completed</span>
                <TaskCompletionBars
                  tasks={tasks.data ? agentTasks : undefined}
                  color="#a47bff"
                  className="wf-detail-mini-chart"
                />
              </div>
            </div>

            <section className="wf-detail-section">
              <h3>About</h3>
              <p className="wf-detail-about">
                {agent.instructions?.trim() ||
                  "No instructions added yet. Edit this agent to define its responsibilities and how it should work."}
              </p>
              <dl className="wf-detail-metadata">
                <div>
                  <dt>Role</dt>
                  <dd>{agent.role_title ?? "—"}</dd>
                </div>
                <div className="wf-detail-last-active">
                  <dt>Last activity</dt>
                  <dd>{agent.last_active_at ? formatRelative(agent.last_active_at) : "Never"}</dd>
                </div>
                <div>
                  <dt>Model quality</dt>
                  <dd className="wf-detail-capitalize">{agent.model_quality ?? "—"}</dd>
                </div>
                <div>
                  <dt>Created</dt>
                  <dd>{agent.inserted_at ? formatDate(agent.inserted_at) : "—"}</dd>
                </div>
                <div className="wf-detail-workspace">
                  <dt>Workspace access</dt>
                  <dd>
                    <span>
                      <i aria-hidden="true" />
                      {workspace?.name ?? "Current workspace"}
                    </span>
                  </dd>
                </div>
              </dl>
            </section>
            <Skills agent={agent} />
            <AgentIntegrations agentId={agent.id} />
          </Tabs.Content>

          <Tabs.Content value="tasks" className="wf-detail-content">
            <div className="wf-detail-section-heading">
              <h3>Assigned tasks</h3>
              <span className="wf-detail-muted">{tasks.data ? agentTasks.length : "—"}</span>
            </div>
            {tasks.isLoading ? (
              <p className="wf-detail-empty" role="status">
                Loading tasks…
              </p>
            ) : tasks.isError ? (
              <div className="wf-detail-empty" role="status">
                Tasks could not be loaded.
                <button
                  type="button"
                  className="wf-detail-text-link"
                  onClick={() => void tasks.refetch()}
                >
                  Try again
                </button>
              </div>
            ) : agentTasks.length === 0 ? (
              <p className="wf-detail-empty">No tasks assigned to this agent yet.</p>
            ) : (
              <div className="wf-detail-task-list">
                {agentTasks.map((task) => (
                  <button
                    type="button"
                    className="wf-detail-task"
                    key={task.id}
                    onClick={() => selectTask(task.id)}
                  >
                    <span>
                      {task.title}
                      <small>{formatRelative(task.updated_at)}</small>
                    </span>
                    <TaskStatusBadge status={task.status} />
                  </button>
                ))}
              </div>
            )}
          </Tabs.Content>

          <Tabs.Content value="skills" className="wf-detail-content">
            <Skills agent={agent} expanded />
          </Tabs.Content>
          <Tabs.Content value="knowledge" className="wf-detail-content">
            <MemoriesSection agent={agent} />
            <Link to="/knowledge" className="wf-detail-text-link">
              Open workspace knowledge <ArrowUpRight size={13} />
            </Link>
          </Tabs.Content>
          <Tabs.Content value="settings" className="wf-detail-content">
            <section className="wf-detail-section">
              <h3>Agent settings</h3>
              <p className="wf-detail-muted">
                Manage this agent’s instructions, permissions, model and automations in its full
                profile.
              </p>
              <dl className="wf-detail-setting-list">
                <div>
                  <dt>Model quality</dt>
                  <dd className="wf-detail-capitalize">{agent.model_quality ?? "—"}</dd>
                </div>
                <div>
                  <dt>Autonomy</dt>
                  <dd className="wf-detail-capitalize">{agent.autonomy_mode ?? "—"}</dd>
                </div>
                <div>
                  <dt>AI enabled</dt>
                  <dd>{agent.ai_enabled ? "Yes" : "No"}</dd>
                </div>
                <div>
                  <dt>Department</dt>
                  <dd>{agent.department ?? "—"}</dd>
                </div>
              </dl>
              <Link
                to="/agents/$agentId"
                params={{ agentId: agent.id }}
                className="wf-detail-button wf-detail-button-primary"
              >
                <Pencil size={14} />
                Edit agent settings
              </Link>
            </section>
          </Tabs.Content>
        </div>
      </Tabs.Root>

      <footer className="wf-detail-footer">
        <button
          type="button"
          className="wf-detail-button"
          onClick={() => openChat(agent.id)}
          disabled={agent.kind === "human_linked"}
          title={
            agent.kind === "human_linked" ? "Chat is available for AI and hybrid agents" : undefined
          }
        >
          <MessageSquare size={15} />
          Test agent
        </button>
        <Link
          to="/agents/$agentId"
          params={{ agentId: agent.id }}
          className="wf-detail-button wf-detail-button-primary"
        >
          <Pencil size={15} />
          Edit agent
        </Link>
      </footer>
    </aside>
  );
}
