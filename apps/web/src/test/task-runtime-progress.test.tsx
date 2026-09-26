import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import type { TaskRuntime } from "@mokaid/shared-types";
import { TaskRuntimeProgress } from "@/components/tasks/task-runtime-progress";
import { RunTimeline } from "@/components/tasks/run-timeline";
import type { TaskRun } from "@/api/types";
import { useDeliverableStore } from "@/stores/deliverable-store";

afterEach(() => {
  cleanup();
  useDeliverableStore.getState().closeDeliverable();
});
const runtime: TaskRuntime = {
  engine: "openai_agents",
  status: "waiting_for_budget",
  participants: [
    {
      agent_id: "researcher",
      name: "Sira",
      status: "completed",
      assignment: "Inspect the public site",
      artifacts: ["audit.pdf"],
    },
    {
      agent_id: "writer",
      name: "Navi",
      status: "running",
      assignment: "Combine findings",
      artifacts: [],
    },
  ],
  budget: {
    limit_credits: 500,
    reserved_credits: 500,
    used_credits: 400,
    remaining_credits: 100,
    estimated: true,
    usage_complete: true,
  },
  verification: {
    passed: false,
    checks: [
      { name: "Sources checked", passed: true },
      { name: "Private analytics", passed: false, message: "Access is missing" },
    ],
  },
  limitations: ["Search Console access is missing"],
  manifest: [
    {
      id: "saved-file",
      filename: "audit.pdf",
      mime_type: "application/pdf",
      agent_id: "researcher",
    },
  ],
};

describe("managed task progress", () => {
  it("keeps legacy runs unchanged", () => {
    const { container } = render(<TaskRuntimeProgress />);
    expect(container).toBeEmptyDOMElement();
  });
  it("shows separate contributors, shared credits and honest delivery checks", () => {
    render(<TaskRuntimeProgress runtime={runtime} />);
    expect(screen.getByText("Paused: credit limit reached")).toBeInTheDocument();
    expect(screen.getByText("Sira")).toBeInTheDocument();
    expect(screen.getByText("Navi")).toBeInTheDocument();
    expect(screen.getByText("Combine findings")).toBeInTheDocument();
    expect(within(screen.getByLabelText("Mission credits")).getByText("400")).toBeInTheDocument();
    expect(screen.getByText("Estimated used")).toBeInTheDocument();
    expect(screen.getByText("Delivery needs checking")).toBeInTheDocument();
    expect(screen.getByText("Search Console access is missing")).toBeInTheDocument();
    expect(screen.queryByText("Delivery checks passed")).not.toBeInTheDocument();
    expect(screen.getByLabelText("Not confirmed")).toBeInTheDocument();
  });
  it("deduplicates saved deliverables and opens the authenticated Drive identity", () => {
    render(
      <TaskRuntimeProgress
        runtime={runtime}
        attachments={[
          {
            id: "saved-file",
            name: "audit.pdf",
            source: "output",
            mime_type: "application/pdf",
            extension: "pdf",
            size_bytes: 42,
            inserted_at: "2026-09-25",
          },
        ]}
      />,
    );
    const buttons = within(screen.getByLabelText("Consolidated deliverables")).getAllByRole(
      "button",
    );
    expect(buttons).toHaveLength(1);
    fireEvent.click(buttons[0]);
    expect(useDeliverableStore.getState().file).toEqual({
      id: "saved-file",
      name: "audit.pdf",
      mime_type: "application/pdf",
    });
  });
  it("does not report unknown credits as zero or empty checks as verified", () => {
    render(
      <TaskRuntimeProgress
        runtime={{
          engine: "openai_agents",
          status: "running",
          budget: {
            used_credits: null,
            remaining_credits: null,
            estimated: true,
            usage_complete: false,
          },
          verification: { passed: true, checks: [] },
        }}
      />,
    );
    expect(screen.getAllByText("Unavailable")).toHaveLength(4);
    expect(screen.getByText("Delivery checks pending")).toBeInTheDocument();
  });
  it("does not count a previous run's attachment as a new consolidated deliverable", () => {
    render(
      <TaskRuntimeProgress
        runtime={{ ...runtime, manifest: [] }}
        attachments={[
          {
            id: "old-report",
            name: "previous.pdf",
            source: "output",
            mime_type: "application/pdf",
            extension: "pdf",
            size_bytes: 42,
            inserted_at: "2026-09-20",
          },
        ]}
      />,
    );
    expect(screen.queryByRole("button", { name: "previous.pdf" })).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Consolidated deliverables")).not.toBeInTheDocument();
  });
  it("attributes activity to its actual contributor", () => {
    const run = {
      id: "run-one",
      tool_activity: [
        {
          id: "run-one:1",
          tool: "web_search",
          description: "Checking sources",
          status: "ok",
          agent_id: "researcher",
          agent_name: "Sira",
        },
      ],
    } as TaskRun;
    render(<RunTimeline taskId="task-one" run={run} working={false} />);
    expect(screen.getByText("· Sira")).toBeInTheDocument();
  });
  it("resolves attribution from the roster when only an agent id is streamed", () => {
    const run = {
      id: "run-two",
      output: { runtime },
      tool_activity: [
        {
          id: "run-two:1",
          tool: "web_search",
          description: "Checking sources",
          status: "ok",
          agent_id: "researcher",
        },
      ],
    } as TaskRun;
    render(<RunTimeline taskId="task-two" run={run} working={false} />);
    expect(screen.getByText("· Sira")).toBeInTheDocument();
  });
});
