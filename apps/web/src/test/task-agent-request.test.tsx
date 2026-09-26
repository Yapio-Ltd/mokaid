import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { TaskAgentRequest } from "@/components/tasks/task-agent-request";
import type { TaskPendingApproval } from "@/api/types";
import { useAuthStore } from "@/stores/auth-store";

const fetchMock = vi.fn();
function request(tool = "send_email"): TaskPendingApproval {
  return {
    id: "pending-known-id",
    run_id: "run-one",
    tool_name: tool,
    risk_level: "high",
    proposed_action: "Send the report to alex@example.test",
    input_payload: {},
    inserted_at: "2026-09-25T10:00:00Z",
  };
}
function renderRequest(pending: TaskPendingApproval | null) {
  return render(
    <QueryClientProvider client={new QueryClient()}>
      <TaskAgentRequest taskId="task-one" request={pending} />
    </QueryClientProvider>,
  );
}
beforeEach(() => {
  fetchMock.mockReset();
  vi.stubGlobal("fetch", fetchMock);
  useAuthStore.setState({ token: "browser:test-csrf", workspaceId: "workspace-one" });
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("inline agent request", () => {
  it("never asks permission to export a PDF", () => {
    renderRequest(request("export_pdf"));
    expect(screen.queryByRole("region", { name: "Agent request" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("answers a real external request using its known ID, without a technical form", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ data: { id: "pending-known-id", status: "approved" } }), {
        status: 200,
      }),
    );
    renderRequest(request());
    expect(screen.getByText("Send the report to alex@example.test")).toBeInTheDocument();
    expect(screen.queryByText("pending-known-id")).not.toBeInTheDocument();
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Allow once" }));
    await screen.findByText("Your answer was sent to the agent.");
    expect(new URL(fetchMock.mock.calls[0][0]).pathname).toBe("/api/tasks/task-one/approve-action");
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({
      approval_request_id: "pending-known-id",
      decision: "approved",
    });
  });

  it("keeps genuine site delivery choices usable inline", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ data: { id: "pending-known-id", status: "edited" } }), {
        status: 200,
      }),
    );
    const pending = request("choose_site_delivery");
    pending.input_payload = { kind: "site_delivery_choice" };
    renderRequest(pending);
    fireEvent.click(screen.getByRole("button", { name: /Simple vitrine HTML/ }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({
      approval_request_id: "pending-known-id",
      decision: "edited",
      payload: { delivery: "html" },
    });
  });

  it("lets the user decline an action and retry a failed answer", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ error: { message: "Unavailable" } }), { status: 503 }),
    );
    renderRequest(request());
    fireEvent.click(screen.getByRole("button", { name: "Skip action" }));
    await screen.findByRole("alert");
    expect(JSON.parse(fetchMock.mock.calls[0][1].body).decision).toBe("rejected");
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Skip action" })).toBeEnabled();
  });
});
