import { useMemo, useState } from "react";
import { Link } from "@tanstack/react-router";
import {
  BarChart3,
  Bot,
  CircleGauge,
  LayoutGrid,
  List,
  Plus,
  RefreshCw,
  Search,
  Users,
  X,
} from "lucide-react";
import { useAgents, useTasks } from "@/api/hooks";
import type { Agent, Task } from "@/api/types";
import { WorkforceAgentPortrait } from "@/components/agents/workforce-agent-portrait";
import { WorkforceAgentActions } from "@/components/agents/workforce-agent-actions";
import { TaskActivitySparkline } from "@/components/agents/workforce-metrics";
import { WorkforceAgentPanel } from "@/components/agents/workforce-agent-panel";
import { formatRelative } from "@/lib/format";
import { cn } from "@/lib/cn";
import "@/styles/workforce.css";

const primaryFilters = ["all", "active", "idle", "training"] as const;
const isActive = (agent: Agent) => agent.status === "active" || agent.status === "busy";
const titleCase = (value: string) => value.charAt(0).toUpperCase() + value.slice(1);

function AgentStatus({ agent }: { agent: Agent }) {
  return (
    <span className="wf-status" data-status={agent.status}>
      <i />
      {titleCase(agent.status)}
    </span>
  );
}

function Performance({ score, tasks }: { score: number | null; tasks: Task[] | undefined }) {
  return (
    <div className="wf-performance">
      <TaskActivitySparkline tasks={tasks} color="#53c5f7" />
      <span>{score == null ? "—" : `${Math.round(score)}%`}</span>
    </div>
  );
}

function AgentIdentity({ agent, onSelect }: { agent: Agent; onSelect: () => void }) {
  return (
    <button
      id={`workforce-agent-${agent.id}`}
      className="wf-agent-identity"
      onClick={onSelect}
      aria-label={`View ${agent.display_name}`}
    >
      <WorkforceAgentPortrait agent={agent} />
      <span className="wf-agent-copy">
        <strong>{agent.display_name}</strong>
        <span className="wf-agent-role">
          {agent.role_title || (agent.kind === "human_linked" ? "Human-linked agent" : "AI Agent")}
        </span>
        <span className="wf-skill-tags">
          {agent.skills.slice(0, 3).map((skill) => (
            <span key={skill.name} title={skill.name}>
              {skill.name}
            </span>
          ))}
          {agent.skills.length === 0 && agent.department && <span>{agent.department}</span>}
        </span>
      </span>
    </button>
  );
}

function AgentRow({
  agent,
  selected,
  tasks,
  tasksAvailable,
  onSelect,
}: {
  agent: Agent;
  selected: boolean;
  tasks: Task[];
  tasksAvailable: boolean;
  onSelect: () => void;
}) {
  const currentTask = tasks.find((task) => task.id === agent.current_task_id);
  const activeTasks = tasks.filter((task) => !["completed", "canceled"].includes(task.status));
  const running = tasks.filter((task) => task.status === "in_progress").length;
  return (
    <tr className={cn("wf-agent-row", selected && "is-selected")} onClick={onSelect}>
      <td className="wf-selection-cell">
        <input
          type="radio"
          name="workforce-agent"
          checked={selected}
          onChange={onSelect}
          onClick={(event) => event.stopPropagation()}
          aria-label={`Select ${agent.display_name}`}
        />
      </td>
      <td>
        <AgentIdentity agent={agent} onSelect={onSelect} />
      </td>
      <td>
        <AgentStatus agent={agent} />
      </td>
      <td>
        <div className="wf-task-count">
          <strong>{tasksAvailable ? activeTasks.length : "—"}</strong>
          <span>
            {tasksAvailable
              ? running
                ? `${running} running`
                : activeTasks.length
                  ? "Queued"
                  : "No tasks"
              : "Unavailable"}
          </span>
        </div>
      </td>
      <td>
        <Performance score={agent.performance_score} tasks={tasksAvailable ? tasks : undefined} />
      </td>
      <td>
        <div className="wf-last-activity">
          <span>{agent.last_active_at ? formatRelative(agent.last_active_at) : "Never"}</span>
          <p>
            {currentTask?.title ||
              (!tasksAvailable && agent.current_task_id
                ? "Task activity unavailable"
                : agent.last_active_at
                  ? "No task in progress"
                  : "Not started yet")}
          </p>
        </div>
      </td>
      <td onClick={(event) => event.stopPropagation()}>
        <WorkforceAgentActions agent={agent} onSelect={onSelect} />
      </td>
    </tr>
  );
}

export function AgentsPage() {
  const [status, setStatus] = useState("all");
  const [search, setSearch] = useState("");
  const [view, setView] = useState<"list" | "grid">("list");
  // undefined chooses the first real agent; null explicitly closes the inspector.
  const [selectedId, setSelectedId] = useState<string | null | undefined>();
  const { data, isLoading, isError, refetch } = useAgents();
  const { data: tasksData, isError: tasksError } = useTasks();
  const allAgents = data?.data ?? [];
  const agents = useMemo(
    () =>
      (data?.data ?? []).filter((agent) => {
        const matchesStatus =
          status === "all" || (status === "active" ? isActive(agent) : agent.status === status);
        const query = search.trim().toLowerCase();
        return (
          matchesStatus &&
          (!query ||
            [
              agent.display_name,
              agent.role_title,
              agent.department,
              ...agent.skills.map((skill) => skill.name),
            ].some((value) => value?.toLowerCase().includes(query)))
        );
      }),
    [data, status, search],
  );
  const tasksByAgent = useMemo(() => {
    const byAgent = new Map<string, Task[]>();
    for (const task of tasksData?.data ?? []) {
      if (task.assigned_agent_id)
        byAgent.set(task.assigned_agent_id, [...(byAgent.get(task.assigned_agent_id) ?? []), task]);
    }
    return byAgent;
  }, [tasksData]);
  const selectedAgent =
    selectedId === null
      ? null
      : (agents.find((agent) => agent.id === selectedId) ?? agents[0] ?? null);
  const activeCount = allAgents.filter(isActive).length;
  const scores = allAgents.flatMap((agent) =>
    agent.performance_score == null ? [] : [agent.performance_score],
  );
  const averagePerformance = scores.length
    ? `${Math.round(scores.reduce((sum, score) => sum + score, 0) / scores.length)}%`
    : "—";
  const completed = allAgents.reduce((sum, agent) => sum + (agent.missions_completed ?? 0), 0);
  const newThisMonth = allAgents.filter((agent) => {
    const date = new Date(agent.inserted_at);
    const now = new Date();
    return date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth();
  }).length;
  const counts = data?.meta.counts;
  const atLimit = counts != null && counts.total >= counts.limit;
  const extraStatuses = [...new Set(allAgents.map((agent) => agent.status))].filter(
    (value) => !["active", "busy", "idle", "training"].includes(value),
  );
  const filterCount = (value: string) =>
    value === "all"
      ? allAgents.length
      : value === "active"
        ? activeCount
        : allAgents.filter((agent) => agent.status === value).length;
  const select = (id: string) => {
    setSelectedId(id);
    if (
      typeof window.matchMedia === "function" &&
      window.matchMedia("(max-width: 1200px)").matches
    ) {
      requestAnimationFrame(() => {
        const panel = document.querySelector<HTMLElement>(".wf-detail-panel");
        panel?.focus({ preventScroll: true });
        panel?.scrollIntoView({
          block: "start",
          behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches
            ? "auto"
            : "smooth",
        });
      });
    }
  };
  const closeInspector = () => {
    const id = selectedAgent?.id;
    setSelectedId(null);
    if (id) requestAnimationFrame(() => document.getElementById(`workforce-agent-${id}`)?.focus());
  };

  return (
    <section className="wf-agents" aria-labelledby="workforce-heading">
      <header className="wf-page-heading">
        <div>
          <p className="wf-eyebrow">AGENTS</p>
          <h1 id="workforce-heading">Your AI workforce</h1>
          <p>Build, manage and scale your team of AI agents.</p>
        </div>
        <Link
          className="wf-create-button"
          to={atLimit ? "/billing" : "/agents/new"}
          data-tour="new-agent"
        >
          {atLimit ? "Upgrade for more seats" : "Create agent"}
          <Plus size={18} />
        </Link>
      </header>
      <div className={cn("wf-workspace", !selectedAgent && "wf-workspace--expanded")}>
        <div className="wf-roster">
          <div className="wf-toolbar">
            <div className="wf-filters" role="group" aria-label="Filter agents by status">
              {primaryFilters.map((value) => (
                <button
                  key={value}
                  className={cn("wf-filter", status === value && "is-active")}
                  aria-pressed={status === value}
                  onClick={() => setStatus(value)}
                >
                  {value !== "all" && <i data-status={value} />}
                  {value === "all" ? "All agents" : titleCase(value)}
                  <span>{isLoading ? "—" : filterCount(value)}</span>
                </button>
              ))}
              {extraStatuses.length > 0 && (
                <select
                  className={cn(
                    "wf-filter wf-more-status",
                    extraStatuses.includes(status as Agent["status"]) && "is-active",
                  )}
                  aria-label="Other agent statuses"
                  value={extraStatuses.includes(status as Agent["status"]) ? status : ""}
                  onChange={(event) => setStatus(event.target.value || "all")}
                >
                  <option value="">More</option>
                  {extraStatuses.map((value) => (
                    <option key={value} value={value}>
                      {titleCase(value)} ({filterCount(value)})
                    </option>
                  ))}
                </select>
              )}
            </div>
            <div className="wf-view-tools">
              <div className="wf-view-toggle" role="group" aria-label="Agent view">
                <button
                  className={view === "list" ? "is-active" : ""}
                  aria-label="List view"
                  aria-pressed={view === "list"}
                  onClick={() => setView("list")}
                >
                  <List size={17} />
                </button>
                <button
                  className={view === "grid" ? "is-active" : ""}
                  aria-label="Grid view"
                  aria-pressed={view === "grid"}
                  onClick={() => setView("grid")}
                >
                  <LayoutGrid size={16} />
                </button>
              </div>
              <label className="wf-search">
                <Search size={15} />
                <input
                  type="search"
                  placeholder="Search agents..."
                  aria-label="Search agents"
                  value={search}
                  onChange={(event) => setSearch(event.target.value)}
                />
              </label>
            </div>
          </div>
          {tasksError && (
            <p className="wf-data-notice" role="status">
              Task activity is unavailable. Agent profiles are still up to date.
            </p>
          )}
          <div className="wf-roster-content">
            {isLoading ? (
              <div className="wf-loading" role="status" aria-label="Loading agents">
                {Array.from({ length: 5 }, (_, index) => (
                  <div key={index}>
                    <span />
                    <span />
                    <span />
                  </div>
                ))}
              </div>
            ) : isError ? (
              <div className="wf-empty">
                <Bot size={30} />
                <h2>Unable to load your agents</h2>
                <p>Check your connection and try again.</p>
                <button className="wf-secondary-button" onClick={() => void refetch()}>
                  <RefreshCw size={15} />
                  Try again
                </button>
              </div>
            ) : agents.length === 0 ? (
              <div className="wf-empty">
                <Bot size={32} />
                <h2>{allAgents.length ? "No matching agents" : "Your team starts here"}</h2>
                <p>
                  {allAgents.length
                    ? "Try a different name, skill or status."
                    : "Create your first agent to get your AI workforce to work."}
                </p>
                {allAgents.length ? (
                  <button
                    className="wf-secondary-button"
                    onClick={() => {
                      setSearch("");
                      setStatus("all");
                    }}
                  >
                    <X size={15} />
                    Clear filters
                  </button>
                ) : (
                  <Link className="wf-create-button" to="/agents/new">
                    <Plus size={16} />
                    Create agent
                  </Link>
                )}
              </div>
            ) : view === "list" ? (
              <div className="wf-table-scroll">
                <table className="wf-table">
                  <colgroup>
                    <col className="wf-col-select" />
                    <col className="wf-col-agent" />
                    <col className="wf-col-status" />
                    <col className="wf-col-tasks" />
                    <col className="wf-col-performance" />
                    <col className="wf-col-activity" />
                    <col className="wf-col-menu" />
                  </colgroup>
                  <thead>
                    <tr>
                      <th aria-label="Selection" />
                      <th>Agent</th>
                      <th>Status</th>
                      <th>Tasks</th>
                      <th title="Current performance score; chart shows tasks completed in the last 14 days">
                        Performance
                      </th>
                      <th>Last activity</th>
                      <th aria-label="Actions" />
                    </tr>
                  </thead>
                  <tbody>
                    {agents.map((agent) => (
                      <AgentRow
                        key={agent.id}
                        agent={agent}
                        selected={selectedAgent?.id === agent.id}
                        tasks={tasksByAgent.get(agent.id) ?? []}
                        tasksAvailable={!!tasksData}
                        onSelect={() => select(agent.id)}
                      />
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <div className="wf-agent-grid">
                {agents.map((agent) => (
                  <article
                    key={agent.id}
                    className={cn("wf-grid-card", selectedAgent?.id === agent.id && "is-selected")}
                  >
                    <div className="wf-grid-top">
                      <AgentStatus agent={agent} />
                      <WorkforceAgentActions agent={agent} onSelect={() => select(agent.id)} />
                    </div>
                    <AgentIdentity agent={agent} onSelect={() => select(agent.id)} />
                    <div className="wf-grid-bottom">
                      <span>{agent.missions_completed ?? 0} missions completed</span>
                      <Performance
                        score={agent.performance_score}
                        tasks={tasksData ? (tasksByAgent.get(agent.id) ?? []) : undefined}
                      />
                    </div>
                  </article>
                ))}
              </div>
            )}
          </div>
          <div className="wf-summary" aria-label="Workforce statistics">
            <div className="wf-summary-card" data-tone="purple">
              <span className="wf-summary-icon">
                <Users size={24} />
              </span>
              <div>
                <strong>{data ? allAgents.length : "—"}</strong>
                <span>Total agents</span>
                <small>{data ? `+${newThisMonth} this month` : "Loading workforce"}</small>
              </div>
            </div>
            <div className="wf-summary-card" data-tone="green">
              <span className="wf-summary-icon">
                <Bot size={24} />
              </span>
              <div>
                <strong>{data ? activeCount : "—"}</strong>
                <span>Active now</span>
                <small>
                  {data
                    ? `${allAgents.length ? Math.round((activeCount / allAgents.length) * 100) : 0}% of total`
                    : "Loading activity"}
                </small>
              </div>
            </div>
            <div className="wf-summary-card" data-tone="blue">
              <span className="wf-summary-icon">
                <BarChart3 size={24} />
              </span>
              <div>
                <strong>{data ? completed : "—"}</strong>
                <span>Missions completed</span>
                <small>Across your team</small>
              </div>
            </div>
            <div className="wf-summary-card" data-tone="amber">
              <span className="wf-summary-icon">
                <CircleGauge size={24} />
              </span>
              <div>
                <strong>{data ? averagePerformance : "—"}</strong>
                <span>Avg. performance</span>
                <small>
                  {scores.length
                    ? `${scores.length} rated ${scores.length === 1 ? "agent" : "agents"}`
                    : "No scores yet"}
                </small>
              </div>
            </div>
          </div>
        </div>
        {selectedAgent && (
          <WorkforceAgentPanel
            key={selectedAgent.id}
            agent={selectedAgent}
            onClose={closeInspector}
          />
        )}
      </div>
    </section>
  );
}
