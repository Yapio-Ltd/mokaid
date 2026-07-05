import { Link } from "@tanstack/react-router";
import * as Switch from "@radix-ui/react-switch";
import { Plug } from "lucide-react";
import { useAgentMcpGrants, useMcpHub, useSetMcpGrant } from "@/api/hooks";
import { McpLogo } from "@/components/mcp/mcp-logo";

/**
 * Permission matrix: which installed MCP servers this agent may use.
 * A missing grant means "not granted" — access is always explicit.
 */
export function AgentMcpMatrix({ agentId }: { agentId: string }) {
  const { data: hubData } = useMcpHub();
  const { data: grantsData } = useAgentMcpGrants(agentId);
  const setGrant = useSetMcpGrant();

  const installations = (hubData?.data.installations ?? []).filter(
    (i) => i.status === "connected",
  );
  const grants = grantsData?.data ?? [];
  const grantByInstallation = new Map(grants.map((g) => [g.installation_id, g]));

  if (installations.length === 0) {
    return (
      <div className="space-y-3 py-6 text-center">
        <Plug size={20} className="mx-auto text-text-muted" />
        <p className="text-xs text-text-muted">
          No MCP server installed in this workspace yet.
        </p>
        <Link
          to="/integrations"
          className="text-xs font-medium text-primary-light hover:underline"
        >
          Open the MCP Hub
        </Link>
      </div>
    );
  }

  return (
    <div className="space-y-1">
      <p className="pb-2 text-[11px] leading-relaxed text-text-muted">
        Choose which connected tools this agent is allowed to use during its runs.
      </p>
      {installations.map((installation) => {
        const grant = grantByInstallation.get(installation.id);
        const granted = grant?.granted ?? false;

        return (
          <div
            key={installation.id}
            className="flex items-center justify-between gap-3 rounded-md px-1 py-2"
          >
            <div className="flex min-w-0 items-center gap-2.5">
              <McpLogo
                slug={installation.logo_slug}
                name={installation.server_name}
                category={installation.category}
                size="sm"
              />
              <div className="min-w-0">
                <p className="truncate text-xs font-medium text-text">
                  {installation.server_name}
                </p>
                {installation.connected_account && (
                  <p className="truncate text-[10px] text-text-muted">
                    {installation.connected_account}
                  </p>
                )}
              </div>
            </div>
            <Switch.Root
              checked={granted}
              disabled={setGrant.isPending}
              onCheckedChange={(checked) =>
                setGrant.mutate({ agentId, installationId: installation.id, granted: checked })
              }
              className="relative h-5 w-9 shrink-0 rounded-full bg-surface-overlay transition-colors data-[state=checked]:bg-primary mk-focus-ring"
            >
              <Switch.Thumb className="block h-4 w-4 translate-x-0.5 rounded-full bg-white transition-transform data-[state=checked]:translate-x-[18px]" />
            </Switch.Root>
          </div>
        );
      })}
    </div>
  );
}
