import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AgentAvatar } from "@/components/agents/agent-avatar";

vi.mock("@/components/ui/avatar", () => ({
  Avatar: ({ name }: { name: string }) => <span data-testid="initials">{name}</span>,
}));
vi.mock("@/three/agent-preview", () => ({
  AgentHeadPreview3D: ({ cdnPath }: { cdnPath: string }) => (
    <span data-testid="live-head" data-model={cdnPath} />
  ),
}));

const agent = {
  display_name: "Goku",
  kind: "ai" as const,
  avatar_config: {},
  avatar_asset_id: "custom-goku",
  avatar_portrait_url: "https://assets.example.test/goku/portrait.png",
  avatar_thumbnail_url: "https://assets.example.test/goku/body.png",
  level: 1,
  xp: 0,
  xp_for_next_level: 100,
};

afterEach(cleanup);

describe("Agent head portraits", () => {
  it("uses the generated head portrait even in tiny chat avatars", () => {
    render(<AgentAvatar agent={agent} size="xs" showRing={false} />);
    expect(screen.getByRole("img", { name: "Goku avatar" })).toHaveAttribute(
      "src",
      agent.avatar_portrait_url,
    );
    expect(screen.queryByTestId("live-head")).not.toBeInTheDocument();
  });

  it("keeps initials for an unresolved custom avatar instead of borrowing a catalog face", () => {
    render(<AgentAvatar agent={{ ...agent, avatar_portrait_url: undefined }} showRing={false} />);
    expect(screen.getByTestId("initials")).toHaveTextContent("Goku");
    expect(screen.queryByRole("img")).not.toBeInTheDocument();
    expect(screen.queryByTestId("live-head")).not.toBeInTheDocument();
  });

  it("falls back safely when a head portrait fails and recovers for its replacement", () => {
    const { rerender } = render(<AgentAvatar agent={agent} showRing={false} />);
    fireEvent.error(screen.getByRole("img"));
    expect(screen.getByTestId("initials")).toBeInTheDocument();
    const replacement = "https://assets.example.test/goku/portrait-v2.png";
    rerender(
      <AgentAvatar agent={{ ...agent, avatar_portrait_url: replacement }} showRing={false} />,
    );
    expect(screen.getByRole("img")).toHaveAttribute("src", replacement);
  });

  it("preserves the custom model head renderer when no static portrait exists", async () => {
    const custom = {
      ...agent,
      avatar_portrait_url: undefined,
      avatar_cdn_path: "https://assets.example.test/goku.glb",
    };
    render(<AgentAvatar agent={custom} showRing={false} />);
    expect(await screen.findByTestId("live-head")).toHaveAttribute(
      "data-model",
      custom.avatar_cdn_path,
    );
    expect(screen.queryByRole("img")).not.toBeInTheDocument();
  });
});
