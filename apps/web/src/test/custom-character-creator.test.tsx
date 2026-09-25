import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CustomCharacterCreator } from "@/components/agents/custom-character-creator";
import type { AvatarGeneration } from "@/api/avatar-generations";
import type { Asset3d } from "@/api/hooks";

const mocks = vi.hoisted(() => ({
  history: [] as AvatarGeneration[],
  current: undefined as AvatarGeneration | undefined,
  mutate: vi.fn(),
  reload: vi.fn(),
  detailError: false,
}));
vi.mock("@/api/avatar-generations", async (original) => {
  const actual = await original<typeof import("@/api/avatar-generations")>();
  return {
    ...actual,
    useAvatarGenerations: () => ({ data: mocks.history, refetch: mocks.reload, isError: false }),
    useAvatarGeneration: () => ({ data: mocks.current, isError: mocks.detailError }),
    useCreateAvatarGeneration: () => ({ mutateAsync: mocks.mutate, isPending: false }),
  };
});

const asset: Asset3d = {
  id: "custom-asset",
  slug: "custom_nova",
  kind: "character",
  cdn_path: "https://cdn.example/custom.glb",
  storage_key: "custom.glb",
  url: "https://cdn.example/custom.glb",
  sha256: "hash",
  byte_size: 123,
  animation_clips: ["walking"],
  metadata: { display_name: "Nova" },
  inserted_at: "2026-09-25T10:00:00Z",
};
const generation: AvatarGeneration = {
  id: "job-one",
  mode: "text",
  name: "Nova",
  status: "generating",
  progress: 42,
  asset_id: null,
  asset: null,
  error: null,
  thumbnail_url: null,
  inserted_at: "2026-09-25T10:00:00Z",
  updated_at: "2026-09-25T10:00:00Z",
};

beforeEach(() => {
  vi.clearAllMocks();
  mocks.history = [];
  mocks.current = undefined;
  mocks.detailError = false;
  mocks.mutate.mockResolvedValue(generation);
  vi.stubGlobal(
    "URL",
    Object.assign(URL, {
      createObjectURL: vi.fn(() => "blob:reference-photo"),
      revokeObjectURL: vi.fn(),
    }),
  );
});
afterEach(cleanup);

function setup(mode: "text" | "image" = "text") {
  const props = {
    mode,
    name: "Nova",
    selectedAssetId: "",
    onSelect: vi.fn(),
    onReadyChange: vi.fn(),
  };
  const view = render(<CustomCharacterCreator {...props} />);
  return { props, ...view };
}

describe("Custom character creation", () => {
  it("submits a trimmed description and blocks use until generation finishes", async () => {
    const { props } = setup();
    expect(screen.getByRole("button", { name: "Generate 3D character" })).toBeDisabled();
    fireEvent.change(screen.getByLabelText("Character description"), {
      target: { value: "  A friendly astronaut  " },
    });
    fireEvent.click(screen.getByRole("button", { name: "Generate 3D character" }));
    await waitFor(() =>
      expect(mocks.mutate).toHaveBeenCalledWith({
        mode: "text",
        prompt: "A friendly astronaut",
        name: "Nova",
      }),
    );
    expect(await screen.findByRole("progressbar")).toHaveAttribute("aria-valuenow", "42");
    expect(props.onReadyChange).toHaveBeenLastCalledWith(false);
    expect(props.onSelect).not.toHaveBeenCalled();
  });

  it("previews and uploads a supported photo", async () => {
    setup("image");
    const photo = new File(["photo bytes"], "portrait.jpg", { type: "image/jpeg" });
    fireEvent.change(screen.getByLabelText("Character photo"), { target: { files: [photo] } });
    expect(await screen.findByAltText("Your reference photo")).toHaveAttribute(
      "src",
      "blob:reference-photo",
    );
    fireEvent.click(screen.getByRole("button", { name: "Generate 3D character" }));
    await waitFor(() =>
      expect(mocks.mutate).toHaveBeenCalledWith({ mode: "image", file: photo, name: "Nova" }),
    );
  });

  it("rejects unsupported and oversized photos without sending them", () => {
    setup("image");
    fireEvent.change(screen.getByLabelText("Character photo"), {
      target: { files: [new File(["svg"], "picture.svg", { type: "image/svg+xml" })] },
    });
    expect(screen.getByRole("alert")).toHaveTextContent("Choose a JPG or PNG photo.");
    fireEvent.change(screen.getByLabelText("Character photo"), {
      target: { files: [new File(["webp"], "picture.webp", { type: "image/webp" })] },
    });
    expect(screen.getByRole("alert")).toHaveTextContent("Choose a JPG or PNG photo.");
    const tooLarge = new File(["x"], "large.png", { type: "image/png" });
    Object.defineProperty(tooLarge, "size", { value: 10 * 1024 * 1024 + 1 });
    fireEvent.change(screen.getByLabelText("Character photo"), { target: { files: [tooLarge] } });
    expect(screen.getByRole("alert")).toHaveTextContent("under 10 MB");
    expect(screen.getByRole("button", { name: "Generate 3D character" })).toBeDisabled();
    expect(mocks.mutate).not.toHaveBeenCalled();
  });

  it("recovers a server-side in-progress job and explains network interruptions", () => {
    mocks.history = [generation];
    mocks.detailError = true;
    const { props } = setup();
    expect(screen.getByRole("progressbar")).toHaveAttribute("aria-valuenow", "42");
    expect(screen.getByRole("alert")).toHaveTextContent("your generation continues");
    expect(screen.getByLabelText("Character description")).toBeDisabled();
    expect(props.onReadyChange).toHaveBeenLastCalledWith(false);
    expect(mocks.mutate).not.toHaveBeenCalled();
  });

  it("selects the completed custom asset and enables use only after completion", async () => {
    const { props, rerender } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Space explorer" }));
    fireEvent.click(screen.getByRole("button", { name: "Generate 3D character" }));
    await screen.findByRole("progressbar");
    mocks.current = { ...generation, status: "ready", progress: 100, asset_id: asset.id, asset };
    rerender(<CustomCharacterCreator {...props} />);
    await waitFor(() => expect(props.onSelect).toHaveBeenCalledWith(asset));
    rerender(<CustomCharacterCreator {...props} selectedAssetId={asset.id} />);
    expect(props.onReadyChange).toHaveBeenLastCalledWith(true);
    expect(screen.getByText("Your character is ready")).toBeInTheDocument();
  });

  it("reuses a saved character without paying for another generation", () => {
    mocks.history = [{ ...generation, status: "ready", progress: 100, asset_id: asset.id, asset }];
    const { props } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Nova Select" }));
    expect(props.onSelect).toHaveBeenCalledWith(asset);
    expect(mocks.mutate).not.toHaveBeenCalled();
  });

  it("shows API failures and preserves the description for a deliberate retry", async () => {
    mocks.mutate.mockRejectedValue(
      new Error("Meshy is temporarily unavailable. Try again shortly."),
    );
    setup();
    fireEvent.change(screen.getByLabelText("Character description"), {
      target: { value: "A cheerful designer" },
    });
    fireEvent.click(screen.getByRole("button", { name: "Generate 3D character" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("temporarily unavailable");
    expect(screen.getByLabelText("Character description")).toHaveValue("A cheerful designer");
    expect(mocks.mutate).toHaveBeenCalledTimes(1);
  });
});
