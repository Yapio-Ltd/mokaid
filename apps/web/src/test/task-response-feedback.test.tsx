import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ComponentProps } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { TaskResponseFeedback } from "@/components/tasks/task-response-feedback";
import { useAuthStore } from "@/stores/auth-store";
import { useTaskFeedbackStore } from "@/stores/task-feedback-store";

type FeedbackTask = ComponentProps<typeof TaskResponseFeedback>["task"];
const fetchMock = vi.fn();

function task(id = "task-one", runId = "run-one"): FeedbackTask {
  return {
    id,
    assigned_agent_id: "agent-one",
    response_feedback: null,
    pending_approval: null,
    latest_run: {
      id: runId,
      status: "completed",
      error: null,
      output: { summary: "Here is the research report." },
      token_usage: null,
      cost_cents: null,
      credits_charged: 0,
      started_at: null,
      completed_at: null,
      inserted_at: "2026-09-25T10:00:00Z",
    },
  };
}

function renderFeedback(initialTask = task()) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const view = (currentTask: FeedbackTask) => (
    <QueryClientProvider client={client}>
      <TaskResponseFeedback task={currentTask} />
    </QueryClientProvider>
  );
  const result = render(view(initialTask));
  return { ...result, client, showTask: (next: FeedbackTask) => result.rerender(view(next)) };
}

beforeEach(() => {
  fetchMock.mockReset();
  vi.stubGlobal("fetch", fetchMock);
  useAuthStore.setState({ token: "browser:test-csrf", workspaceId: "workspace-one" });
  useTaskFeedbackStore.setState({ drafts: {} });
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("task response feedback", () => {
  it("records a good response against the visible run and refreshes task data", async () => {
    const updated = { ...task(), status: "completed" };
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ data: updated }), { status: 200 }));
    const { client } = renderFeedback();
    fireEvent.click(screen.getByRole("button", { name: "Good response" }));

    await screen.findByText("Thanks for your feedback.");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, request] = fetchMock.mock.calls[0];
    expect(new URL(url).pathname).toBe("/api/tasks/task-one/feedback");
    expect(JSON.parse(request.body)).toEqual({ rating: "good", run_id: "run-one" });
    expect(request.headers).toMatchObject({ "x-workspace-id": "workspace-one" });
    expect(client.getQueryData(["tasks", "workspace-one", "detail", "task-one"])).toEqual({
      data: updated,
    });
    expect(screen.getByRole("button", { name: "Good response" })).toBeDisabled();
  });

  it("requires an improvement prompt and resumes the same task with the trimmed instructions", async () => {
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ data: task() }), { status: 202 }));
    renderFeedback();
    fireEvent.click(screen.getByRole("button", { name: "Needs improvement" }));
    const submit = screen.getByRole("button", { name: "Continue task" });
    expect(submit).toBeDisabled();
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "   " } });
    expect(submit).toBeDisabled();
    fireEvent.change(screen.getByRole("textbox"), {
      target: { value: "  Add sources and finish the report.  " },
    });
    fireEvent.click(submit);
    await screen.findByText("Your instructions were sent. The agent is continuing this task.");
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({
      rating: "needs_improvement",
      prompt: "Add sources and finish the report.",
      run_id: "run-one",
    });
    expect(useTaskFeedbackStore.getState().drafts).toEqual({});
  });

  it("preserves the prompt after a failed submission and does not automatically retry", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ error: { message: "Connection interrupted" } }), {
        status: 503,
      }),
    );
    const first = renderFeedback();
    fireEvent.click(screen.getByRole("button", { name: "Needs improvement" }));
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "Keep these instructions" } });
    fireEvent.click(screen.getByRole("button", { name: "Continue task" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Your instructions are saved");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("textbox")).toHaveValue("Keep these instructions");
    first.unmount();
    renderFeedback();
    expect(screen.getByRole("textbox")).toHaveValue("Keep these instructions");
  });

  it("keeps another task's draft intact when an earlier task finishes submitting", async () => {
    let resolveRequest!: (response: Response) => void;
    fetchMock.mockImplementation(
      () =>
        new Promise<Response>((resolve) => {
          resolveRequest = resolve;
        }),
    );
    const { showTask } = renderFeedback();
    fireEvent.click(screen.getByRole("button", { name: "Needs improvement" }));
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "First task instructions" } });
    fireEvent.click(screen.getByRole("button", { name: "Continue task" }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    expect(screen.getByRole("button", { name: "Continue task" })).toBeDisabled();
    showTask(task("task-two", "run-two"));
    fireEvent.click(screen.getByRole("button", { name: "Needs improvement" }));
    fireEvent.change(screen.getByRole("textbox"), {
      target: { value: "Second task instructions" },
    });

    await act(async () => {
      resolveRequest(new Response(JSON.stringify({ data: task() }), { status: 202 }));
    });
    expect(screen.getByRole("textbox")).toHaveValue("Second task instructions");
    expect(
      useTaskFeedbackStore.getState().drafts["workspace-one:task-one:run-one"],
    ).toBeUndefined();
    expect(
      screen.queryByText("Your instructions were sent. The agent is continuing this task."),
    ).not.toBeInTheDocument();
  });

  it("keeps drafts separate when switching tasks and when a new result arrives", () => {
    const { showTask } = renderFeedback();
    fireEvent.click(screen.getByRole("button", { name: "Needs improvement" }));
    fireEvent.change(screen.getByRole("textbox"), {
      target: { value: "Original result feedback" },
    });
    showTask(task("task-two", "run-two"));
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
    showTask(task());
    expect(screen.getByRole("textbox")).toHaveValue("Original result feedback");
    showTask(task("task-one", "new-run"));
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
  });

  it("never asks for feedback or permission for a pending PDF export", () => {
    const paused = task();
    paused.latest_run = { ...paused.latest_run!, status: "waiting_for_approval", output: null };
    paused.pending_approval = {
      id: "legacy",
      tool_name: "export_pdf",
      run_id: "run-one",
      proposed_action: "Export PDF",
      risk_level: "medium",
      input_payload: {},
      inserted_at: "2026-09-25T10:00:00Z",
    };
    renderFeedback(paused);
    expect(screen.queryByRole("button", { name: "Good response" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Needs improvement" })).not.toBeInTheDocument();
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("lets users provide missing instructions without marking an unfinished response as good", () => {
    const paused = task();
    paused.latest_run = { ...paused.latest_run!, status: "waiting_for_user_input", output: null };
    renderFeedback(paused);
    expect(screen.getByRole("button", { name: "Good response" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "Needs improvement" }));
    expect(screen.getByRole("textbox")).toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("does not carry a good rating onto a newer response", () => {
    const newer = task("task-one", "new-run");
    newer.response_feedback = {
      rating: "good",
      prompt: null,
      run_id: "run-one",
      submitted_by_member_id: "member-one",
      submitted_at: "2026-09-25T10:00:00Z",
    };
    renderFeedback(newer);
    expect(screen.queryByText("Thanks for your feedback.")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Good response" })).toBeEnabled();
  });
});
