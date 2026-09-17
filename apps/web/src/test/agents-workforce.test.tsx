import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { forwardRef, type ComponentProps, type ComponentRef } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Agent, AgentCounts, Task } from "@/api/types";
import { AgentsPage } from "@/pages/agents";

const mocks = vi.hoisted(() => ({
  useAgents: vi.fn(),
  useTasks: vi.fn(),
  refetch: vi.fn(),
  openChat: vi.fn(),
}));

vi.mock("@/api/hooks", () => ({ useAgents: mocks.useAgents, useTasks: mocks.useTasks }));
vi.mock("@tanstack/react-router", () => ({
  Link: forwardRef<
    ComponentRef<"a">,
    ComponentProps<"a"> & { to: string; params?: { agentId: string } }
  >(({ to, params, ...props }, ref) => (
    <a ref={ref} {...props} href={to.replace("$agentId", params?.agentId ?? "")} />
  )),
}));
vi.mock("@/components/agents/agent-avatar", () => ({
  AgentAvatar: ({ agent }: { agent: Agent }) => (
    <span role="img" aria-label={`${agent.display_name} avatar`} />
  ),
}));
vi.mock("@/components/agents/workforce-agent-panel", () => ({
  WorkforceAgentPanel: ({ agent, onClose }: { agent: Agent; onClose: () => void }) => (
    <aside aria-label={`${agent.display_name} profile`}>
      <button onClick={onClose}>Close profile</button>
    </aside>
  ),
}));
vi.mock("@/stores/chat-store", () => ({
  useChatStore: (selector: (store: { openChat: typeof mocks.openChat }) => unknown) =>
    selector({ openChat: mocks.openChat }),
}));

function makeAgent(id: string, displayName: string, overrides: Partial<Agent> = {}): Agent {
  return {
    id,
    workspace_id: "workspace-one",
    display_name: displayName,
    kind: "ai",
    slug: id,
    email_alias: null,
    avatar_config: {},
    avatar_asset_id: null,
    role_title: "Researcher",
    department: "Operations",
    status: "idle",
    presence_status: "online",
    control_mode: "ai_controlled",
    ai_enabled: true,
    human_takeover_enabled: false,
    skills: [],
    capabilities: null,
    autonomy_mode: "balanced",
    instructions: null,
    model_quality: "smart",
    tool_preferences: {},
    current_task_id: null,
    performance_score: null,
    level: 1,
    xp: 0,
    xp_for_next_level: 100,
    missions_completed: 0,
    seat_index: null,
    office_activity: null,
    office_poi_id: null,
    office_slot_id: null,
    office_activity_phase: null,
    office_activity_ends_at: null,
    linked_user_id: null,
    linked_member_id: null,
    linked_user_name: null,
    linked_user_email: null,
    last_active_at: null,
    inserted_at: new Date().toISOString(),
    ...overrides,
  };
}

function makeTask(id: string, agentId: string | null, status: Task["status"], title = id): Task {
  return {
    id,
    workspace_id: "workspace-one",
    project_id: null,
    project_name: null,
    title,
    description: null,
    status,
    priority: "medium",
    assigned_agent_id: agentId,
    assigned_agent_name: null,
    assigned_agent_kind: null,
    due_at: null,
    started_at: null,
    completed_at: null,
    progress_percent: 0,
    requires_approval: false,
    tags: [],
    position: 0,
    subtask_count: 0,
    subtask_done_count: 0,
    subtasks: [],
    comments: [],
    attachments: [],
    latest_run: null,
    pending_approval: null,
    conversation_id: null,
    chat_agent_id: null,
    domain_requested: [],
    capability_match: null,
    composite: null,
    composite_parent_id: null,
    inserted_at: "2026-09-01T10:00:00Z",
    updated_at: "2026-09-01T10:00:00Z",
  };
}

function setAgents(agents: Agent[], counts: Partial<AgentCounts> = {}) {
  mocks.useAgents.mockReturnValue({
    data: { data: agents, meta: { counts: { total: agents.length, limit: 9, ...counts } } },
    isLoading: false,
    isError: false,
    refetch: mocks.refetch,
  });
}

function setTasks(tasks: Task[]) {
  mocks.useTasks.mockReturnValue({ data: { data: tasks }, isError: false });
}

function statistic(label: string) {
  const summary = screen.getByLabelText("Workforce statistics");
  return within(within(summary).getByText(label).parentElement!);
}

function visibleAgents() {
  return screen
    .queryAllByRole("button", { name: /^View / })
    .map((button) => button.getAttribute("aria-label"));
}

beforeEach(() => {
  vi.clearAllMocks();
  setAgents([
    makeAgent("orion", "Orion", {
      status: "busy",
      performance_score: 80,
      missions_completed: 4,
      current_task_id: "running",
      skills: [{ name: "Rust", level: 80 }],
    }),
    makeAgent("mira", "Mira", {
      status: "active",
      performance_score: 60,
      missions_completed: 9,
      role_title: "Legal specialist",
      skills: [{ name: "Contract review", level: 60 }],
    }),
    makeAgent("vale", "Vale", { performance_score: 0 }),
    makeAgent("iris", "Iris", { status: "blocked", missions_completed: 2 }),
    makeAgent("nova", "Nova", { status: "training" }),
  ]);
  setTasks([
    makeTask("done", "orion", "completed"),
    makeTask("running", "orion", "in_progress", "Compile customer portal"),
    makeTask("queued", "orion", "to_do"),
    makeTask("canceled", "orion", "canceled"),
    makeTask("other-agent", "mira", "in_progress"),
    makeTask("unassigned", null, "in_progress"),
  ]);
});

afterEach(cleanup);

describe("Agents workforce", () => {
  it("does not offer AI chat for a human-linked team member", () => {
    setAgents([makeAgent("human", "Human colleague", { kind: "human_linked" })]);
    render(<AgentsPage />);
    fireEvent.keyDown(screen.getByRole("button", { name: "Actions for Human colleague" }), {
      key: "Enter",
    });
    const testAction = screen.getByRole("menuitem", { name: "Test agent" });
    expect(testAction).toHaveAttribute("aria-disabled", "true");
    fireEvent.click(testAction);
    expect(mocks.openChat).not.toHaveBeenCalled();
  });

  it("uses workspace data for totals, averages and assigned task activity", () => {
    render(<AgentsPage />);

    expect(statistic("Total agents").getByText("5")).toBeInTheDocument();
    expect(statistic("Active now").getByText("2")).toBeInTheDocument();
    expect(statistic("Active now").getByText("40% of total")).toBeInTheDocument();
    expect(statistic("Missions completed").getByText("15")).toBeInTheDocument();
    // An actual zero is rated; missing performance must not be averaged as zero.
    expect(statistic("Avg. performance").getByText("47%")).toBeInTheDocument();
    expect(statistic("Avg. performance").getByText("3 rated agents")).toBeInTheDocument();
    const orion = within(screen.getByRole("button", { name: "View Orion" }).closest("tr")!);
    expect(orion.getByText("2")).toBeInTheDocument();
    expect(orion.getByText("1 running")).toBeInTheDocument();
    expect(orion.getByText("Compile customer portal")).toBeInTheDocument();
    expect(orion.getByText("80%")).toBeInTheDocument();
    const iris = within(screen.getByRole("button", { name: "View Iris" }).closest("tr")!);
    expect(iris.getByText("—")).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Create agent" })).toHaveAttribute(
      "href",
      "/agents/new",
    );
    expect(mocks.useAgents).toHaveBeenCalledWith();
  });

  it("searches names and skills case-insensitively while keeping workspace totals", () => {
    render(<AgentsPage />);
    const search = screen.getByRole("searchbox", { name: "Search agents" });
    fireEvent.change(search, { target: { value: "  CONTRact  " } });
    expect(visibleAgents()).toEqual(["View Mira"]);
    expect(screen.getByRole("complementary", { name: "Mira profile" })).toBeInTheDocument();
    expect(statistic("Total agents").getByText("5")).toBeInTheDocument();
    fireEvent.change(search, { target: { value: "oRiOn" } });
    expect(visibleAgents()).toEqual(["View Orion"]);
  });

  it("includes busy agents in Active and keeps other backend statuses accessible", () => {
    render(<AgentsPage />);
    fireEvent.click(screen.getByRole("button", { name: /^Active 2$/ }));
    expect(visibleAgents()).toEqual(["View Orion", "View Mira"]);
    expect(screen.getByRole("button", { name: /^Active 2$/ })).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    fireEvent.click(screen.getByRole("button", { name: /^Idle 1$/ }));
    expect(visibleAgents()).toEqual(["View Vale"]);
    fireEvent.click(screen.getByRole("button", { name: /^Training 1$/ }));
    expect(visibleAgents()).toEqual(["View Nova"]);
    fireEvent.change(screen.getByRole("combobox", { name: "Other agent statuses" }), {
      target: { value: "blocked" },
    });
    expect(visibleAgents()).toEqual(["View Iris"]);
    fireEvent.click(screen.getByRole("button", { name: /^All agents 5$/ }));
    expect(visibleAgents()).toHaveLength(5);
  });

  it("switches between list and grid without losing the selected agent", () => {
    render(<AgentsPage />);
    fireEvent.click(screen.getByRole("button", { name: "View Mira" }));
    fireEvent.click(screen.getByRole("button", { name: "Grid view" }));
    expect(screen.queryByRole("table")).not.toBeInTheDocument();
    expect(screen.getAllByRole("article")).toHaveLength(5);
    expect(screen.getByRole("complementary", { name: "Mira profile" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Grid view" })).toHaveAttribute(
      "aria-pressed",
      "true",
    );
    fireEvent.click(screen.getByRole("button", { name: "List view" }));
    expect(screen.getByRole("table")).toBeInTheDocument();
    expect(screen.getByRole("radio", { name: "Select Mira" })).toBeChecked();
  });

  it("supports selecting, closing and reopening the inspector, with a visible filtered fallback", () => {
    render(<AgentsPage />);
    expect(screen.getByRole("complementary", { name: "Orion profile" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("radio", { name: "Select Mira" }));
    expect(screen.getByRole("complementary", { name: "Mira profile" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /^Idle 1$/ }));
    expect(screen.getByRole("complementary", { name: "Vale profile" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Close profile" }));
    expect(screen.queryByRole("complementary")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /^All agents 5$/ }));
    expect(screen.queryByRole("complementary")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "View Iris" }));
    expect(screen.getByRole("complementary", { name: "Iris profile" })).toBeInTheDocument();
  });

  it("clears combined search and status filters when no agents match", () => {
    render(<AgentsPage />);
    fireEvent.click(screen.getByRole("button", { name: /^Idle 1$/ }));
    fireEvent.change(screen.getByRole("searchbox"), { target: { value: "no such agent" } });
    expect(screen.getByRole("heading", { name: "No matching agents" })).toBeInTheDocument();
    expect(screen.queryByRole("complementary")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Clear filters" }));
    expect(screen.getByRole("searchbox")).toHaveValue("");
    expect(visibleAgents()).toHaveLength(5);
    expect(screen.getByRole("button", { name: /^All agents 5$/ })).toHaveAttribute(
      "aria-pressed",
      "true",
    );
  });

  it("shows an empty workspace honestly and offers agent creation", () => {
    setAgents([]);
    setTasks([]);
    render(<AgentsPage />);
    expect(screen.getByRole("heading", { name: "Your team starts here" })).toBeInTheDocument();
    expect(statistic("Total agents").getByText("0")).toBeInTheDocument();
    expect(statistic("Avg. performance").getByText("—")).toBeInTheDocument();
    expect(screen.queryByRole("complementary")).not.toBeInTheDocument();
    for (const link of screen.getAllByRole("link", { name: "Create agent" }))
      expect(link).toHaveAttribute("href", "/agents/new");
  });

  it("shows loading separately from an empty team and offers retry after an agent request fails", () => {
    mocks.useAgents.mockReturnValue({
      data: undefined,
      isLoading: true,
      isError: false,
      refetch: mocks.refetch,
    });
    const { rerender } = render(<AgentsPage />);
    expect(screen.getByRole("status", { name: "Loading agents" })).toBeInTheDocument();
    expect(screen.queryByText("Your team starts here")).not.toBeInTheDocument();
    mocks.useAgents.mockReturnValue({
      data: undefined,
      isLoading: false,
      isError: true,
      refetch: mocks.refetch,
    });
    rerender(<AgentsPage />);
    expect(screen.getByRole("heading", { name: "Unable to load your agents" })).toBeInTheDocument();
    expect(statistic("Total agents").getByText("—")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(mocks.refetch).toHaveBeenCalledOnce();
  });

  it("keeps profiles visible when tasks fail and does not claim zero tasks", () => {
    mocks.useTasks.mockReturnValue({ data: undefined, isError: true });
    render(<AgentsPage />);
    expect(screen.getByRole("status")).toHaveTextContent("Task activity is unavailable");
    expect(visibleAgents()).toHaveLength(5);
    expect(screen.getByRole("complementary", { name: "Orion profile" })).toBeInTheDocument();
    const row = within(screen.getByRole("button", { name: "View Orion" }).closest("tr")!);
    expect(row.getByText("Unavailable")).toBeInTheDocument();
    expect(row.queryByText("No tasks")).not.toBeInTheDocument();
  });

  it("preserves plan limits by sending the creation action to billing", () => {
    setAgents([makeAgent("only", "Only agent")], { total: 1, limit: 1 });
    render(<AgentsPage />);
    expect(screen.getByRole("link", { name: "Upgrade for more seats" })).toHaveAttribute(
      "href",
      "/billing",
    );
    expect(screen.queryByRole("link", { name: "Create agent" })).not.toBeInTheDocument();
  });
});
