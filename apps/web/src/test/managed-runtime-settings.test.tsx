import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ManagedRuntimeSettings } from "@/components/settings/managed-runtime-settings";
import { useAuthStore } from "@/stores/auth-store";

const fetchMock = vi.fn();
const policy = {
  enabled: false,
  data_policy_accepted: false,
  data_region: "US",
  zero_data_retention: false,
  max_active_sessions: 4,
  standard_credits: 500,
  complex_credits: 2000,
};
function response(canUpdate = true, data = policy) {
  return new Response(JSON.stringify({ data, meta: { can_update: canUpdate } }), { status: 200 });
}
function renderSettings() {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <ManagedRuntimeSettings />
    </QueryClientProvider>,
  );
}
beforeEach(() => {
  fetchMock.mockReset();
  vi.stubGlobal("fetch", fetchMock);
  useAuthStore.setState({ token: "browser:test", workspaceId: "workspace-one", user: null });
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("workspace managed execution", () => {
  it("defaults off and requires consent before an administrator can enable it", async () => {
    fetchMock
      .mockResolvedValueOnce(response())
      .mockResolvedValueOnce(
        response(true, { ...policy, enabled: true, data_policy_accepted: true }),
      );
    renderSettings();
    const toggle = await screen.findByRole("switch", { name: "Enable managed task execution" });
    expect(toggle).not.toBeChecked();
    expect(toggle).toBeDisabled();
    expect(screen.getByRole("button", { name: "Save execution settings" })).toBeDisabled();
    fireEvent.click(
      screen.getByRole("checkbox", { name: /I authorize.*United States.*Zero data retention/ }),
    );
    fireEvent.click(toggle);
    fireEvent.click(screen.getByRole("button", { name: "Save execution settings" }));
    await screen.findByText("Managed execution settings saved.");
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(new URL(fetchMock.mock.calls[1][0]).pathname).toBe("/api/ai/runtime-policy");
    expect(fetchMock.mock.calls[1][1].headers["x-workspace-id"]).toBe("workspace-one");
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({
      enabled: true,
      data_policy_accepted: true,
    });
  });
  it("keeps ordinary members read-only", async () => {
    fetchMock.mockResolvedValue(response(false));
    renderSettings();
    expect(await screen.findByRole("switch")).toBeDisabled();
    expect(screen.getByRole("checkbox")).toBeDisabled();
    expect(
      screen.queryByRole("button", { name: "Save execution settings" }),
    ).not.toBeInTheDocument();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
  it("revokes activation together with consent", async () => {
    fetchMock
      .mockResolvedValueOnce(
        response(true, { ...policy, enabled: true, data_policy_accepted: true }),
      )
      .mockResolvedValueOnce(response());
    renderSettings();
    await screen.findByRole("switch");
    fireEvent.click(screen.getByRole("checkbox"));
    expect(screen.getByRole("switch")).not.toBeChecked();
    fireEvent.click(screen.getByRole("button", { name: "Save execution settings" }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    expect(JSON.parse(fetchMock.mock.calls[1][1].body)).toEqual({
      enabled: false,
      data_policy_accepted: false,
    });
  });
  it("does not claim a failed save succeeded and allows retry", async () => {
    fetchMock
      .mockResolvedValueOnce(response())
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ error: { message: "Saving unavailable" } }), { status: 503 }),
      );
    renderSettings();
    await screen.findByRole("switch");
    fireEvent.click(screen.getByRole("checkbox"));
    fireEvent.click(screen.getByRole("button", { name: "Save execution settings" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Saving unavailable");
    expect(screen.queryByText("Managed execution settings saved.")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Save execution settings" })).toBeEnabled();
  });
  it("keeps a delayed save scoped to its original workspace", async () => {
    let finishSave!: (value: Response) => void;
    fetchMock
      .mockResolvedValueOnce(response())
      .mockImplementationOnce(
        () =>
          new Promise<Response>((resolve) => {
            finishSave = resolve;
          }),
      )
      .mockResolvedValueOnce(response(false));
    renderSettings();
    await screen.findByRole("switch");
    fireEvent.click(screen.getByRole("checkbox"));
    fireEvent.click(screen.getByRole("switch"));
    fireEvent.click(screen.getByRole("button", { name: "Save execution settings" }));
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    act(() => useAuthStore.setState({ workspaceId: "workspace-two" }));
    await screen.findByText("Only a workspace administrator can change this setting.");
    await act(async () => {
      finishSave(response(true, { ...policy, enabled: true, data_policy_accepted: true }));
    });
    expect(screen.getByRole("switch")).not.toBeChecked();
    expect(screen.getByRole("switch")).toBeDisabled();
    expect(screen.queryByText("Managed execution settings saved.")).not.toBeInTheDocument();
    expect(fetchMock.mock.calls[1][1].headers["x-workspace-id"]).toBe("workspace-one");
    expect(fetchMock.mock.calls[2][1].headers["x-workspace-id"]).toBe("workspace-two");
  });
});
