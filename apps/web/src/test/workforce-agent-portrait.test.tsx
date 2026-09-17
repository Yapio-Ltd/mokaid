import { readFileSync } from "node:fs";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  resolveWorkforceAgentPortrait,
  WorkforceAgentPortrait,
} from "@/components/agents/workforce-agent-portrait";
import { DEFAULT_AVATAR_CDN_PATH, resolveAgentGlbUrl } from "@/three/agent-cdn";

vi.mock("@/components/agents/agent-avatar", () => ({
  AgentAvatar: ({ agent }: { agent: { display_name: string; avatar_cdn_path?: string } }) => (
    <span data-testid="existing-avatar" data-source={agent.avatar_cdn_path}>
      {agent.display_name}
    </span>
  ),
}));

const agent = {
  display_name: "Agent with a custom name",
  kind: "ai" as const,
  avatar_config: {},
  avatar_asset_id: null,
  level: 1,
  xp: 0,
  xp_for_next_level: 100,
};

const provenance = JSON.parse(
  readFileSync("public/branding/agent-portraits/provenance.json", "utf8"),
) as {
  portraits: { avatar_cdn_path: string; sourceSha256: string; render: string }[];
};

afterEach(cleanup);

describe("Workforce agent portraits", () => {
  it.each(provenance.portraits)(
    "maps only the exact rendered source $avatar_cdn_path",
    ({ avatar_cdn_path, sourceSha256, render: portrait }) => {
      expect(avatar_cdn_path).toContain(sourceSha256.slice(0, 12));
      expect(resolveWorkforceAgentPortrait({ ...agent, avatar_cdn_path })).toBe(portrait);
      expect(
        resolveWorkforceAgentPortrait({
          ...agent,
          avatar_cdn_path: avatar_cdn_path.slice(1),
        }),
      ).toBe(portrait);
      expect(
        resolveWorkforceAgentPortrait({
          ...agent,
          avatar_cdn_path: resolveAgentGlbUrl(avatar_cdn_path),
        }),
      ).toBe(portrait);
    },
  );

  it("resolves an unassigned avatar through the existing default CDN logic", () => {
    const defaultPortrait = provenance.portraits.find(
      (portrait) => portrait.avatar_cdn_path === DEFAULT_AVATAR_CDN_PATH,
    );
    expect(defaultPortrait).toBeDefined();
    expect(resolveWorkforceAgentPortrait(agent)).toBe(defaultPortrait?.render);
    expect(resolveWorkforceAgentPortrait({ ...agent, avatar_cdn_path: "  " })).toBe(
      defaultPortrait?.render,
    );
  });

  it("does not replace custom locations, old hashes, or unresolved assigned assets", () => {
    for (const avatar_cdn_path of [
      "/uploads/avatar_male.21ca01757e1a.glb",
      "https://custom.example/assets3d/avatar_male.21ca01757e1a.glb",
      "/assets3d/avatar_male.e5faef146311.glb",
      "/assets3d/avatar_male.glb",
      "/uploads/my-agent.glb",
    ]) {
      expect(resolveWorkforceAgentPortrait({ ...agent, avatar_cdn_path })).toBeNull();
    }
    expect(resolveWorkforceAgentPortrait({ ...agent, avatar_asset_id: "custom-asset" })).toBeNull();
  });

  it("preserves human avatars and supports hybrid agents with known models", () => {
    expect(resolveWorkforceAgentPortrait({ ...agent, kind: "human_linked" })).toBeNull();
    expect(resolveWorkforceAgentPortrait({ ...agent, kind: "hybrid" })).toBe(
      resolveWorkforceAgentPortrait(agent),
    );
  });

  it("preserves a custom avatar even when an agent name or role resembles a stock model", () => {
    const customAgent = {
      ...agent,
      display_name: "Legal",
      role_title: "Developer",
      avatar_cdn_path: "/uploads/custom.glb",
    };
    render(<WorkforceAgentPortrait agent={customAgent} />);
    expect(screen.getByTestId("existing-avatar")).toHaveAttribute(
      "data-source",
      customAgent.avatar_cdn_path,
    );
    expect(screen.queryByRole("img")).not.toBeInTheDocument();
  });

  it("falls back to the existing avatar when its portrait fails to load", () => {
    const { rerender } = render(<WorkforceAgentPortrait agent={agent} />);
    fireEvent.error(screen.getByRole("img", { name: `${agent.display_name} avatar` }));
    expect(screen.getByTestId("existing-avatar")).toHaveTextContent(agent.display_name);
    rerender(
      <WorkforceAgentPortrait
        agent={{ ...agent, avatar_cdn_path: provenance.portraits[1].avatar_cdn_path }}
        size="detail"
      />,
    );
    expect(screen.getByRole("img")).toHaveAttribute("src", provenance.portraits[1].render);
    expect(screen.queryByTestId("existing-avatar")).not.toBeInTheDocument();
  });
});
