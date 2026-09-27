import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Agent, DispatchAnalysis } from "@/api/types";
import { NewTaskModal } from "@/components/modals/new-task-modal";

type RosterAgent = Pick<Agent, "id" | "display_name" | "kind" | "status" | "ai_enabled">;

const mocks = vi.hoisted(() => ({
  analyze: vi.fn(),
  create: vi.fn(),
  attach: vi.fn(),
  execute: vi.fn(),
  toast: vi.fn(),
  close: vi.fn(),
  agents: [] as RosterAgent[],
}));

vi.mock("@/api/hooks", () => ({
  useAgents: () => ({ data: { data: mocks.agents } }),
  useProjects: () => ({ data: { data: [] } }),
  useCreateTask: () => ({ mutateAsync: mocks.create }),
  useAttachTaskFile: () => ({ mutateAsync: mocks.attach }),
  useExecuteAi: () => ({ mutate: mocks.execute }),
  useDispatchAnalyze: () => ({ mutateAsync: mocks.analyze }),
}));
vi.mock("@/stores/toast-store", () => ({ toast: mocks.toast }));
vi.mock("@/components/ui/select", () => ({
  Select: ({
    value,
    onValueChange,
    options,
    placeholder,
  }: {
    value?: string;
    onValueChange: (value: string) => void;
    options: { value: string; label: string }[];
    placeholder: string;
  }) => (
    <select
      aria-label={placeholder}
      value={value ?? ""}
      onChange={(event) => onValueChange(event.target.value)}
    >
      <option value="">{placeholder}</option>
      {options.map((option) => (
        <option key={option.value} value={option.value}>
          {option.label}
        </option>
      ))}
    </select>
  ),
}));

function analysis(overrides: Partial<DispatchAnalysis["recommendation"]> = {}): {
  data: DispatchAnalysis;
} {
  const customAgent =
    overrides.mode === "custom_agent" || overrides.mode === "user_choice"
      ? {
          display_name: "Infrastructure specialist",
          role_title: "DevOps Engineer",
          department: "Engineering",
          archetype_key: "devops",
          skills: [{ name: "Kubernetes diagnostics", level: 40 }],
        }
      : null;
  return {
    data: {
      task: {
        title: "Investigate failing pods",
        description: "Diagnose Kubernetes failures",
        priority: "high",
      },
      recommendation: {
        mode: "existing_agent",
        agent_id: "devops",
        confidence: 90,
        reason: "Matches infrastructure operations",
        alternatives: [],
        custom_agent: customAgent,
        ...overrides,
      },
      domain_categories: ["devops"],
      mcp_suggestions: [],
    },
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  mocks.agents = [
    { id: "devops", display_name: "Ops", kind: "ai", status: "idle", ai_enabled: true },
  ];
  mocks.analyze.mockResolvedValue(analysis());
  mocks.create.mockResolvedValue({ data: { id: "task-created" } });
});
afterEach(cleanup);

function openTask() {
  render(<NewTaskModal open onOpenChange={mocks.close} />);
  fireEvent.change(screen.getByRole("textbox"), {
    target: { value: "Investigate failing Kubernetes pods" },
  });
}

async function submitTask() {
  fireEvent.click(screen.getByRole("button", { name: "Create Task" }));
  await waitFor(() => expect(mocks.close).toHaveBeenCalledWith(false));
}

describe("New Task automatic dispatch", () => {
  it("assigns and starts a clear existing-agent recommendation", async () => {
    openTask();
    await submitTask();
    expect(mocks.create).toHaveBeenCalledWith(
      expect.objectContaining({ assigned_agent_id: "devops" }),
    );
    expect(mocks.execute).toHaveBeenCalledWith({ taskId: "task-created" });
  });

  it.each([
    ["partial fit", { mode: "user_choice" }],
    ["new specialist", { mode: "custom_agent", agent_id: null }],
    ["weak match", { confidence: 30 }],
    ["unknown agent", { agent_id: "missing-agent" }],
  ] satisfies [string, Partial<DispatchAnalysis["recommendation"]>][])(
    "leaves a %s unassigned and never starts a run",
    async (_label, recommendation) => {
      mocks.analyze.mockResolvedValue(analysis(recommendation));
      openTask();
      await submitTask();
      expect(mocks.create).toHaveBeenCalledWith(
        expect.objectContaining({ assigned_agent_id: undefined }),
      );
      expect(mocks.execute).not.toHaveBeenCalled();
      expect(mocks.toast).toHaveBeenCalledWith(
        expect.objectContaining({
          tone: "warning",
          description: expect.stringContaining("created unassigned"),
        }),
      );
    },
  );

  it.each(["training", "disabled"])("does not start an agent who is %s", async (unavailable) => {
    if (unavailable === "training") mocks.agents[0].status = "training";
    else mocks.agents[0].ai_enabled = false;
    openTask();
    await submitTask();
    expect(mocks.create).toHaveBeenCalledWith(
      expect.objectContaining({ assigned_agent_id: undefined }),
    );
    expect(mocks.execute).not.toHaveBeenCalled();
  });

  it("preserves an explicit agent selection despite a partial recommendation", async () => {
    mocks.analyze.mockResolvedValue(analysis({ mode: "user_choice" }));
    openTask();
    fireEvent.click(screen.getByRole("button", { name: "Advanced options" }));
    fireEvent.change(screen.getByLabelText("Auto (recommended)"), { target: { value: "devops" } });
    await submitTask();
    expect(mocks.create).toHaveBeenCalledWith(
      expect.objectContaining({ assigned_agent_id: "devops" }),
    );
    expect(mocks.execute).toHaveBeenCalledWith({ taskId: "task-created" });
    expect(mocks.toast).toHaveBeenCalledWith(expect.objectContaining({ tone: "warning" }));
  });

  it("does not autoassign or start when analysis fails", async () => {
    mocks.analyze.mockRejectedValue(new Error("invalid_dispatch_analysis"));
    openTask();
    await submitTask();
    expect(mocks.create).toHaveBeenCalledWith(
      expect.objectContaining({ assigned_agent_id: undefined }),
    );
    expect(mocks.execute).not.toHaveBeenCalled();
  });

  it("assigns a recommended human without trying to execute AI", async () => {
    mocks.agents[0].kind = "human_linked";
    mocks.agents[0].ai_enabled = false;
    openTask();
    await submitTask();
    expect(mocks.create).toHaveBeenCalledWith(
      expect.objectContaining({ assigned_agent_id: "devops" }),
    );
    expect(mocks.execute).not.toHaveBeenCalled();
  });
});
