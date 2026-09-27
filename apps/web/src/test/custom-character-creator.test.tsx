import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CustomCharacterCreator } from "@/components/agents/custom-character-creator";
import { ApiError } from "@/api/client";
import type { AvatarGeneration, AvatarGenerationQuote } from "@/api/avatar-generations";
import type { Asset3d } from "@/api/hooks";

const mocks = vi.hoisted(() => ({
  history: [] as AvatarGeneration[],
  current: undefined as AvatarGeneration | undefined,
  mutate: vi.fn(),
  reload: vi.fn(),
  detailError: false,
  historyFailed: false,
  loadingQuote: false,
  quote: undefined as AvatarGenerationQuote | undefined,
}));
vi.mock("@/api/avatar-generations", async (original) => {
  const actual = await original<typeof import("@/api/avatar-generations")>();
  return {
    ...actual,
    useAvatarGenerations: () => ({
      data: mocks.history,
      ...mocks.quote,
      refetch: mocks.reload,
      isError: mocks.historyFailed,
      isPending: mocks.loadingQuote,
    }),
    useAvatarGeneration: () => ({ data: mocks.current, isError: mocks.detailError }),
    useCreateAvatarGeneration: () => ({ mutateAsync: mocks.mutate, isPending: false }),
  };
});

vi.mock("@tanstack/react-router", () => ({
  Link: ({ children, to }: { children: React.ReactNode; to: string }) => (
    <a href={to}>{children}</a>
  ),
}));

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
  mocks.historyFailed = false;
  mocks.loadingQuote = false;
  mocks.quote = { pricing: { credits: 1000 }, credits: { spendable: 1500, unlimited: false } };
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
  it("discloses the quoted price, charge timing and failure refund before submission", () => {
    setup();
    expect(
      screen.getByRole("button", { name: "Generate 3D character · 1,000 credits" }),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/1,000 Mokaid credits per character\. Charged when generation starts/),
    ).toHaveTextContent("Automatically refunded if generation fails");
    expect(screen.getByText("Available: 1,500 credits.")).toBeInTheDocument();
  });

  it("waits for a quote and disables generation when pricing cannot load", () => {
    mocks.quote = undefined;
    mocks.loadingQuote = true;
    const { props, rerender } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Space explorer" }));
    expect(screen.getByRole("status")).toHaveTextContent("Checking the generation cost");
    expect(screen.getByRole("button", { name: /Generate 3D character/ })).toBeDisabled();
    mocks.loadingQuote = false;
    rerender(<CustomCharacterCreator {...props} />);
    expect(screen.getByRole("alert")).toHaveTextContent("Generation pricing could not be loaded");
    fireEvent.click(screen.getByRole("button", { name: "Retry pricing" }));
    expect(mocks.reload).toHaveBeenCalledOnce();
    expect(mocks.mutate).not.toHaveBeenCalled();
  });

  it("blocks insufficient funds and links to Billing", () => {
    mocks.quote!.credits.spendable = 200;
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Space explorer" }));
    expect(screen.getByRole("button", { name: /Generate 3D character/ })).toBeDisabled();
    expect(screen.getByRole("alert")).toHaveTextContent("You need 800 more credits");
    expect(screen.getByRole("link", { name: "Add credits in Billing" })).toHaveAttribute(
      "href",
      "/billing",
    );
    expect(mocks.mutate).not.toHaveBeenCalled();
  });

  it("treats an overdrawn balance as insufficient funds with a valid price", () => {
    mocks.quote!.credits.spendable = -100;
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Space explorer" }));
    expect(
      screen.getByRole("button", { name: "Generate 3D character · 1,000 credits" }),
    ).toBeDisabled();
    expect(screen.getByRole("alert")).toHaveTextContent("You need 1,100 more credits");
    expect(screen.queryByText("Generation pricing could not be loaded.")).not.toBeInTheDocument();
    expect(mocks.mutate).not.toHaveBeenCalled();
  });

  it("allows an unlimited workspace to generate with the authoritative quote", async () => {
    mocks.quote = { pricing: { credits: 1250 }, credits: { spendable: 0, unlimited: true } };
    setup();
    expect(
      screen.getByText(/1,250 Mokaid credits per character\. Included in your unlimited plan/),
    ).toBeInTheDocument();
    expect(screen.queryByText(/Charged when generation starts/)).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Space explorer" }));
    fireEvent.click(screen.getByRole("button", { name: "Generate 3D character · 1,250 credits" }));
    await waitFor(() =>
      expect(mocks.mutate).toHaveBeenCalledWith(
        expect.objectContaining({ expected_credits: 1250 }),
      ),
    );
  });

  it("requires a deliberate second click after a price change", async () => {
    mocks.mutate.mockRejectedValue(new ApiError(422, "avatar_price_changed", "Changed"));
    const { props, rerender } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Space explorer" }));
    fireEvent.click(screen.getByRole("button", { name: /Generate 3D character/ }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Review the updated cost");
    expect(mocks.reload).toHaveBeenCalledOnce();
    mocks.quote!.pricing.credits = 1200;
    rerender(<CustomCharacterCreator {...props} />);
    expect(
      screen.getByRole("button", { name: "Generate 3D character · 1,200 credits" }),
    ).toBeEnabled();
    expect(mocks.mutate).toHaveBeenCalledTimes(1);
  });

  it("removes provider branding from photo instructions", () => {
    setup("image");
    expect(
      screen.getByText("Your photo is used to generate your custom 3D character."),
    ).toBeInTheDocument();
    expect(screen.queryByText(/meshy/i)).not.toBeInTheDocument();
  });

  it("submits a trimmed description and blocks use until generation finishes", async () => {
    const { props } = setup();
    expect(screen.getByRole("button", { name: /Generate 3D character/ })).toBeDisabled();
    fireEvent.change(screen.getByLabelText("Character description"), {
      target: { value: "  A friendly astronaut  " },
    });
    fireEvent.click(screen.getByRole("button", { name: /Generate 3D character/ }));
    await waitFor(() =>
      expect(mocks.mutate).toHaveBeenCalledWith({
        mode: "text",
        prompt: "A friendly astronaut",
        name: "Nova",
        expected_credits: 1000,
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
    fireEvent.click(screen.getByRole("button", { name: /Generate 3D character/ }));
    await waitFor(() =>
      expect(mocks.mutate).toHaveBeenCalledWith({
        mode: "image",
        file: photo,
        name: "Nova",
        expected_credits: 1000,
      }),
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
    expect(screen.getByRole("button", { name: /Generate 3D character/ })).toBeDisabled();
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
    fireEvent.click(screen.getByRole("button", { name: /Generate 3D character/ }));
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
      new Error("Character generation is temporarily unavailable. Try again shortly."),
    );
    setup();
    fireEvent.change(screen.getByLabelText("Character description"), {
      target: { value: "A cheerful designer" },
    });
    fireEvent.click(screen.getByRole("button", { name: /Generate 3D character/ }));
    expect(await screen.findByRole("alert")).toHaveTextContent("temporarily unavailable");
    expect(screen.getByLabelText("Character description")).toHaveValue("A cheerful designer");
    expect(mocks.mutate).toHaveBeenCalledTimes(1);
  });
});
