import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { RuntimeBudgetActions } from "@/components/tasks/runtime-budget-actions";
import { TaskRuntimeProgress } from "@/components/tasks/task-runtime-progress";
import { useAuthStore } from "@/stores/auth-store";

const fetchMock = vi.fn();
let sequence = 0;
function renderActions(runId: string) {
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <RuntimeBudgetActions taskId="task-budget" runId={runId} />
    </QueryClientProvider>,
  );
}
function success(runId: string) {
  return new Response(
    JSON.stringify({
      data: { run_id: runId, reserved_credits: 1000, budget_revision: 1, status: "running" },
    }),
    { status: 200 },
  );
}
beforeEach(() => {
  fetchMock.mockReset();
  vi.stubGlobal("fetch", fetchMock);
  sessionStorage.clear();
  useAuthStore.setState({ token: "browser:test", workspaceId: "budget-workspace", user: null });
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("continue a mission with more credits", () => {
  it("sends one explicitly chosen allowance for the current run and confirms resumption", async () => {
    const runId = `budget-run-${++sequence}`;
    fetchMock.mockResolvedValue(success(runId));
    renderActions(runId);
    fireEvent.click(screen.getByRole("button", { name: "+500 credits" }));
    await screen.findByText("Budget increased. The mission is resuming.");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(new URL(fetchMock.mock.calls[0][0]).pathname).toBe(
      "/api/tasks/task-budget/runtime-budget",
    );
    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(body).toMatchObject({ run_id: runId, additional_credits: 500 });
    expect(body.request_id).toMatch(/^[a-f0-9-]{36}$/i);
    expect(screen.getByRole("button", { name: "+500 credits" })).toBeDisabled();
  });
  it("retries an uncertain update with the same UUID and prevents changing the amount", async () => {
    const runId = `budget-run-${++sequence}`;
    fetchMock
      .mockRejectedValueOnce(new Error("Connection lost"))
      .mockResolvedValueOnce(success(runId));
    renderActions(runId);
    fireEvent.click(screen.getByRole("button", { name: "+2,000 credits" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Connection lost");
    expect(screen.getByRole("button", { name: "+500 credits" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "Retry +2,000 credits" }));
    await screen.findByText("Budget increased. The mission is resuming.");
    expect(fetchMock.mock.calls[1][1].body).toBe(fetchMock.mock.calls[0][1].body);
  });
  it("retains an unresolved request when the panel is closed and reopened", async () => {
    const runId = `budget-run-${++sequence}`;
    fetchMock
      .mockRejectedValueOnce(new Error("Connection lost"))
      .mockResolvedValueOnce(success(runId));
    const view = renderActions(runId);
    fireEvent.click(screen.getByRole("button", { name: "+500 credits" }));
    await screen.findByRole("alert");
    view.unmount();
    renderActions(runId);
    fireEvent.click(screen.getByRole("button", { name: "+500 credits" }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    expect(fetchMock.mock.calls[1][1].body).toBe(fetchMock.mock.calls[0][1].body);
  });
  it("retires a successful request even when its panel closed before the response", async () => {
    const runId = `budget-run-${++sequence}`;
    let resolveFirst!: (response: Response) => void;
    fetchMock
      .mockReturnValueOnce(
        new Promise<Response>((resolve) => {
          resolveFirst = resolve;
        }),
      )
      .mockResolvedValueOnce(success(runId));
    const first = renderActions(runId);
    fireEvent.click(screen.getByRole("button", { name: "+500 credits" }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    first.unmount();
    resolveFirst(success(runId));
    await waitFor(() => expect(sessionStorage.length).toBe(0));
    renderActions(runId);
    fireEvent.click(screen.getByRole("button", { name: "+500 credits" }));
    await screen.findByText("Budget increased. The mission is resuming.");
    const firstBody = JSON.parse(fetchMock.mock.calls[0][1].body);
    const secondBody = JSON.parse(fetchMock.mock.calls[1][1].body);
    expect(firstBody.request_id).not.toBe(secondBody.request_id);
  });
  it("does not offer top-ups on active or historical run summaries", () => {
    render(
      <TaskRuntimeProgress
        runtime={{ engine: "openai_agents", status: "running" }}
        taskId="task-budget"
        runId="active"
      />,
    );
    expect(screen.queryByText("+500 credits")).not.toBeInTheDocument();
    cleanup();
    render(
      <TaskRuntimeProgress runtime={{ engine: "openai_agents", status: "waiting_for_budget" }} />,
    );
    expect(screen.queryByText("+500 credits")).not.toBeInTheDocument();
  });
});
