/**
 * AgentAvatar — circular 3D head portrait with optional XP ring.
 *
 * Used everywhere an agent face appears (list, chat, dock, dashboard).
 * Falls back to the 2D Avatar if WebGL fails.
 *
 * Tiny `xs` portraits stay 2D (chat message rows can mount dozens at once and
 * would exhaust the browser WebGL context budget). sm+ keep live Babylon heads.
 */

import { lazy, Suspense } from "react";
import type { Agent } from "@/api/types";
import { Avatar } from "@/components/ui/avatar";
import { AgentLevelRing } from "@/components/agents/agent-level-ring";
import { cn } from "@/lib/cn";
import { DEFAULT_AVATAR_CDN_PATH } from "@/three/agent-model";

const AgentHeadPreview3D = lazy(() =>
  import("@/three/agent-preview").then((m) => ({ default: m.AgentHeadPreview3D })),
);

const SIZE_PX = { xs: 28, sm: 40, md: 48, lg: 64, xl: 96 } as const;

type AgentAvatarSize = keyof typeof SIZE_PX;

type AgentAvatarSource = Pick<
  Agent,
  "display_name" | "kind" | "avatar_config" | "level" | "xp" | "xp_for_next_level"
> & {
  avatar_cdn_path?: string | null;
  avatar_asset_id?: string | null;
};

export function AgentAvatar({
  agent,
  size = "md",
  showBadge = true,
  showRing,
  className,
}: {
  agent: AgentAvatarSource;
  size?: AgentAvatarSize;
  showBadge?: boolean;
  /** Defaults to true for AI agents. */
  showRing?: boolean;
  className?: string;
}) {
  const color = agent.avatar_config?.primary_color ?? (agent.kind === "ai" ? "#5936d1" : "#472aa8");
  const cdnPath = agent.avatar_cdn_path || DEFAULT_AVATAR_CDN_PATH;
  const px = SIZE_PX[size];
  const isAiLike = agent.kind === "ai" || agent.kind === "hybrid";
  const ring = showRing ?? isAiLike;
  // Only message-sized avatars skip WebGL; lists/dock/profile keep 3D.
  const useLive3d = isAiLike && size !== "xs";

  const head = useLive3d ? (
    <Suspense
      fallback={
        <Avatar name={agent.display_name} size={size} isAi color={color} />
      }
    >
      <AgentHeadPreview3D
        name={agent.display_name}
        color={color}
        size={px}
        cdnPath={cdnPath}
        fallbackSize={size}
      />
    </Suspense>
  ) : (
    <Avatar name={agent.display_name} size={size} isAi={isAiLike} color={color} />
  );

  if (!ring) {
    return (
      <span
        className={cn("inline-block shrink-0 [corner-shape:round]", className)}
        style={{
          width: px,
          height: px,
          borderRadius: "50%",
          overflow: "hidden",
          clipPath: "circle(50% at 50% 50%)",
          WebkitClipPath: "circle(50% at 50% 50%)",
        }}
      >
        {head}
      </span>
    );
  }

  return (
    <AgentLevelRing
      level={agent.level ?? 1}
      xp={agent.xp ?? 0}
      xpForNext={agent.xp_for_next_level ?? 100}
      size={size}
      showBadge={showBadge}
      className={className}
    >
      {head}
    </AgentLevelRing>
  );
}
