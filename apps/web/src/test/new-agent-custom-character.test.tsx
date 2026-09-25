import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NewAgentForm } from "@/components/agents/new-agent-form";
import type { Asset3d } from "@/api/hooks";
import type { AvatarGeneration } from "@/api/avatar-generations";

const mocks = vi.hoisted(() => ({
  create: vi.fn(),
  navigate: vi.fn(),
  history: [] as AvatarGeneration[],
}));
const catalogAsset: Asset3d = {
  id: "catalog-asset",
  slug: "avatar_male",
  kind: "character",
  cdn_path: "/assets3d/default.glb",
  storage_key: "default.glb",
  url: "/assets3d/default.glb",
  sha256: "hash",
  byte_size: 100,
  animation_clips: ["walking"],
  metadata: { display_name: "Alex" },
  inserted_at: "2026-09-25T10:00:00Z",
};
const customAsset = {
  ...catalogAsset,
  id: "custom-asset",
  slug: "custom_nova",
  cdn_path: "https://cdn.example/custom.glb",
  metadata: { display_name: "Nova custom" },
};
vi.mock("@tanstack/react-router", () => ({
  useNavigate: () => mocks.navigate,
  Link: ({ children }: { children: ReactNode }) => <a>{children}</a>,
}));
vi.mock("@/api/hooks", () => ({
  useCreateAgent: () => ({ mutateAsync: mocks.create, isPending: false }),
  useAssets3d: () => ({ data: [catalogAsset], isLoading: false, isError: false }),
  useBillingOverview: () => ({ data: { data: { credits: { spendable: 100 } } } }),
  useAgentCatalog: () => ({
    data: {
      data: {
        archetypes: [{ key: "blank", name: "Blank", skills: [], tier: "blank" }],
        boosts: [],
      },
    },
  }),
}));
vi.mock("@/api/avatar-generations", async (original) => ({
  ...(await original<typeof import("@/api/avatar-generations")>()),
  useAvatarGenerations: () => ({ data: mocks.history, refetch: vi.fn(), isError: false }),
  useAvatarGeneration: () => ({ data: undefined, isError: false }),
  useCreateAvatarGeneration: () => ({ mutateAsync: vi.fn(), isPending: false }),
}));
vi.mock("@/three/agent-preview", () => ({
  AgentPreview3D: ({ cdnPath }: { cdnPath: string }) => (
    <span data-testid="model-preview" data-source={cdnPath} />
  ),
}));

beforeEach(() => {
  vi.clearAllMocks();
  mocks.history = [];
  mocks.create.mockResolvedValue({ data: { id: "created-agent" } });
});
afterEach(cleanup);

function characterStep() {
  render(<NewAgentForm />);
  fireEvent.change(screen.getByPlaceholderText("e.g. Nova"), { target: { value: "Nova" } });
  for (let index = 0; index < 4; index++)
    fireEvent.click(screen.getByRole("button", { name: "Next" }));
}

describe("New agent custom avatar assignment", () => {
  it("prevents creating with an unfinished custom character and keeps catalog available", () => {
    characterStep();
    fireEvent.click(screen.getByRole("button", { name: "From a prompt" }));
    expect(screen.getByRole("button", { name: "Create Agent" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "From a photo" }));
    expect(screen.getByRole("button", { name: "Create Agent" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "Choose" }));
    expect(screen.getByRole("button", { name: "Create Agent" })).toBeEnabled();
  });

  it("previews a saved custom GLB and sends its asset ID when creating the agent", async () => {
    mocks.history = [
      {
        id: "generation",
        name: "Nova custom",
        mode: "text",
        status: "ready",
        progress: 100,
        asset_id: customAsset.id,
        asset: customAsset,
        error: null,
        thumbnail_url: null,
        inserted_at: "2026-09-25T10:00:00Z",
        updated_at: "2026-09-25T10:00:00Z",
      },
    ];
    characterStep();
    fireEvent.click(screen.getByRole("button", { name: "From a prompt" }));
    fireEvent.click(screen.getByRole("button", { name: "Nova custom Select" }));
    await waitFor(() =>
      expect(screen.getByTestId("model-preview")).toHaveAttribute(
        "data-source",
        customAsset.cdn_path,
      ),
    );
    expect(screen.getByRole("button", { name: "Create Agent" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "Create Agent" }));
    await waitFor(() =>
      expect(mocks.create).toHaveBeenCalledWith(
        expect.objectContaining({ display_name: "Nova", avatar_asset_id: customAsset.id }),
      ),
    );
  });
});
