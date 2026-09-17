import { useState, type ComponentProps } from "react";
import { AgentAvatar } from "@/components/agents/agent-avatar";
import { cn } from "@/lib/cn";
import { resolveAgentGlbUrl } from "@/three/agent-cdn";
import "./workforce-agent-portrait.css";

type PortraitAgent = ComponentProps<typeof AgentAvatar>["agent"];

/** Exact GLBs rendered by scripts/blender-desktop-portraits.py.
 * Source hashes are recorded in /branding/agent-portraits/provenance.json.
 * Do not infer a portrait from an agent's name, role, or an unhashed filename.
 */
const PORTRAITS = [
  ["avatar_male.21ca01757e1a.glb", "male"],
  ["avatar_design.1c0dba698d81.glb", "design"],
  ["avatar_finance.1db634ff8a82.glb", "finance"],
  ["avatar_corporate.b2951a24cd02.glb", "corporate"],
  ["avatar_developer.867211fc6b99.glb", "developer"],
  ["avatar_research.7c86fc428e9f.glb", "research"],
  ["avatar_legal.859687268a64.glb", "legal"],
  ["avatar_byte.cb5a54d04591.glb", "byte"],
  ["avatar_nyx.90aeb6731720.glb", "nyx"],
  ["avatar_moss.c04355089db5.glb", "moss"],
] as const;

export function resolveWorkforceAgentPortrait(
  agent: Pick<PortraitAgent, "kind" | "avatar_cdn_path" | "avatar_asset_id">,
): string | null {
  if (agent.kind !== "ai" && agent.kind !== "hybrid") return null;
  // An assigned asset without its resolved path must keep the existing renderer.
  if (agent.avatar_asset_id && !agent.avatar_cdn_path?.trim()) return null;

  const source = resolveAgentGlbUrl(agent.avatar_cdn_path);
  const match = PORTRAITS.find(
    ([filename]) => resolveAgentGlbUrl(`/assets3d/${filename}`) === source,
  );
  return match ? `/branding/agent-portraits/portrait-${match[1]}.png` : null;
}

/** Static portraits for the workforce route; other avatar surfaces stay live. */
export function WorkforceAgentPortrait({
  agent,
  className,
  size = "row",
}: {
  agent: PortraitAgent;
  className?: string;
  size?: "row" | "detail";
}) {
  const portrait = resolveWorkforceAgentPortrait(agent);
  const [failedPortrait, setFailedPortrait] = useState<string | null>(null);

  return (
    <span
      className={cn("workforce-agent-portrait", `workforce-agent-portrait--${size}`, className)}
    >
      {portrait && portrait !== failedPortrait ? (
        <img
          className="workforce-agent-portrait__image"
          src={portrait}
          alt={`${agent.display_name} avatar`}
          width={384}
          height={384}
          decoding="async"
          draggable={false}
          onError={() => setFailedPortrait(portrait)}
        />
      ) : (
        <span className="workforce-agent-portrait__fallback">
          <AgentAvatar
            agent={agent}
            size={size === "detail" ? "xl" : "lg"}
            showRing={false}
            showBadge={false}
          />
        </span>
      )}
    </span>
  );
}
