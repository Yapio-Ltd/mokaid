import { useMemo, useState } from "react";
import { Check, Plug, Unplug } from "lucide-react";
import {
  useConnectIntegration,
  useDisconnectIntegration,
  useIntegrations,
} from "@/api/hooks";
import type { IntegrationConnection, IntegrationProvider } from "@/api/types";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { DetailPanel } from "@/components/ui/detail-panel";
import { SearchInput } from "@/components/ui/search-input";
import { SkeletonRows } from "@/components/ui/skeleton";
import { cn } from "@/lib/cn";
import { formatRelative } from "@/lib/format";

const categoryColors: Record<string, string> = {
  Communication: "#60a5fa",
  Storage: "#34d399",
  Productivity: "#fbbf24",
  "Project Management": "#7c5cff",
  Developer: "#f472b6",
  Automation: "#22d3ee",
  CRM: "#f87171",
  Finance: "#a3e635",
};

function providerInitial(name: string): string {
  return name
    .split(/\s+/)
    .slice(0, 2)
    .map((w) => w[0])
    .join("");
}

export function IntegrationsPage() {
  const { data, isLoading } = useIntegrations();
  const connect = useConnectIntegration();
  const disconnect = useDisconnectIntegration();
  const [search, setSearch] = useState("");
  const [selectedKey, setSelectedKey] = useState<string | null>(null);

  const providers = data?.data.providers ?? [];
  const connections = data?.data.connections ?? [];

  const connectionByProvider = useMemo(() => {
    const map = new Map<string, IntegrationConnection>();
    connections.forEach((c) => map.set(c.provider_key, c));
    return map;
  }, [connections]);

  const filtered = useMemo(() => {
    if (!search) return providers;
    const q = search.toLowerCase();
    return providers.filter(
      (p) => p.name.toLowerCase().includes(q) || p.category.toLowerCase().includes(q),
    );
  }, [providers, search]);

  const connectedCount = connections.filter((c) => c.status === "connected").length;
  const selected: IntegrationProvider | null =
    providers.find((p) => p.key === selectedKey) ?? null;
  const selectedConnection = selected ? connectionByProvider.get(selected.key) : undefined;

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-5">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-bold text-text">Integrations</h1>
            <p className="text-xs text-text-muted">
              {connectedCount} connected · {providers.length} available
            </p>
          </div>
          <SearchInput
            placeholder="Search integrations…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-64"
          />
        </div>

        {isLoading ? (
          <SkeletonRows rows={5} />
        ) : (
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {filtered.map((provider) => {
              const connection = connectionByProvider.get(provider.key);
              const isConnected = connection?.status === "connected";

              return (
                <button
                  key={provider.key}
                  onClick={() => setSelectedKey(provider.key)}
                  className={cn(
                    "mk-card flex items-start gap-3 p-4 text-left transition-shadow hover:shadow-glow mk-focus-ring",
                    selectedKey === provider.key && "border-primary/50",
                  )}
                >
                  <span
                    className="flex h-10 w-10 shrink-0 items-center justify-center rounded-md text-sm font-bold text-white"
                    style={{ backgroundColor: categoryColors[provider.category] ?? "#7c5cff" }}
                  >
                    {providerInitial(provider.name)}
                  </span>
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center justify-between gap-2">
                      <p className="truncate text-xs font-semibold text-text">{provider.name}</p>
                      {isConnected ? (
                        <Badge tone="success" dot>
                          Connected
                        </Badge>
                      ) : (
                        <Badge tone="muted">Available</Badge>
                      )}
                    </div>
                    <p className="mt-0.5 line-clamp-2 text-[11px] leading-relaxed text-text-muted">
                      {provider.description}
                    </p>
                    <p className="mt-1.5 text-[10px] font-medium uppercase tracking-wide text-text-muted">
                      {provider.category}
                    </p>
                  </div>
                </button>
              );
            })}
          </div>
        )}
      </div>

      <DetailPanel open={selected != null} onClose={() => setSelectedKey(null)} title="Integration">
        {selected && (
          <div className="space-y-5 px-5 py-4">
            <div className="flex items-center gap-3">
              <span
                className="flex h-12 w-12 items-center justify-center rounded-md text-base font-bold text-white"
                style={{ backgroundColor: categoryColors[selected.category] ?? "#7c5cff" }}
              >
                {providerInitial(selected.name)}
              </span>
              <div>
                <h3 className="text-sm font-bold text-text">{selected.name}</h3>
                <p className="text-[11px] text-text-muted">{selected.category}</p>
              </div>
            </div>

            <p className="text-xs leading-relaxed text-text-secondary">{selected.description}</p>

            {selectedConnection?.status === "connected" ? (
              <>
                <div className="space-y-1.5 text-xs">
                  <div className="flex justify-between">
                    <span className="text-text-muted">Account</span>
                    <span className="text-text">{selectedConnection.connected_account}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-text-muted">Last sync</span>
                    <span className="text-text">
                      {selectedConnection.last_sync_at
                        ? formatRelative(selectedConnection.last_sync_at)
                        : "Never"}
                    </span>
                  </div>
                </div>
                <div className="rounded-md border border-success/25 bg-success-muted px-3 py-2 text-[11px] text-success">
                  <Check size={12} className="mr-1 inline" />
                  This integration is active and available to your agents.
                </div>
                <Button
                  variant="danger"
                  size="sm"
                  className="w-full"
                  loading={disconnect.isPending}
                  onClick={() => disconnect.mutate(selectedConnection.id)}
                >
                  <Unplug size={13} /> Disconnect
                </Button>
              </>
            ) : (
              <Button
                size="sm"
                className="w-full"
                loading={connect.isPending}
                onClick={() => connect.mutate(selected.key)}
              >
                <Plug size={13} /> Connect {selected.name}
              </Button>
            )}
          </div>
        )}
      </DetailPanel>
    </div>
  );
}
