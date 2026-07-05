import { useMemo, useState } from "react";
import { Check, ExternalLink, Plug, Star, Trash2 } from "lucide-react";
import {
  useFigmaOauthStart,
  useGoogleOauthStart,
  useInstallMcp,
  useMcpHub,
  useUninstallMcp,
} from "@/api/hooks";
import type { McpInstallation, McpServer } from "@/api/types";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { DetailPanel } from "@/components/ui/detail-panel";
import { Field } from "@/components/ui/field";
import { SearchInput } from "@/components/ui/search-input";
import { SkeletonRows } from "@/components/ui/skeleton";
import { McpLogo } from "@/components/mcp/mcp-logo";
import { cn } from "@/lib/cn";
import { formatRelative } from "@/lib/format";

const categories = [
  { key: "all", label: "All" },
  { key: "productivity", label: "Productivity" },
  { key: "development", label: "Development" },
  { key: "communication", label: "Communication" },
  { key: "crm", label: "CRM & PM" },
  { key: "finance", label: "Finance" },
  { key: "cloud", label: "Cloud" },
  { key: "database", label: "Databases" },
  { key: "ai", label: "AI" },
  { key: "search", label: "Web Search" },
  { key: "browser", label: "Browser" },
  { key: "design", label: "Design" },
  { key: "docs", label: "Docs" },
  { key: "storage", label: "Storage" },
  { key: "monitoring", label: "Monitoring" },
];

function figmaRedirectUri(): string {
  return `${window.location.origin}/oauth/figma/callback`;
}

function googleRedirectUri(): string {
  return `${window.location.origin}/oauth/google/callback`;
}

const googleServerKeys = new Set([
  "google_drive",
  "gmail",
  "google_calendar",
  "google_docs",
  "google_sheets",
  "google_meet",
]);

function ServerCard({
  server,
  installation,
  selected,
  onSelect,
}: {
  server: McpServer;
  installation: McpInstallation | undefined;
  selected: boolean;
  onSelect: () => void;
}) {
  const isConnected = installation?.status === "connected";

  return (
    <button
      onClick={onSelect}
      className={cn(
        "mk-card flex items-start gap-3 p-4 text-left transition-shadow hover:shadow-glow mk-focus-ring",
        selected && "border-primary/50",
      )}
    >
      <McpLogo slug={server.logo_slug} name={server.name} category={server.category} />
      <div className="min-w-0 flex-1">
        <div className="flex items-center justify-between gap-2">
          <p className="flex items-center gap-1.5 truncate text-xs font-semibold text-text">
            {server.name}
            {server.featured && <Star size={11} className="shrink-0 fill-warning text-warning" />}
          </p>
          {isConnected ? (
            <Badge tone="success" dot>
              Installed
            </Badge>
          ) : installation?.status === "pending" ? (
            <Badge tone="warning">Pending</Badge>
          ) : null}
        </div>
        <p className="mt-0.5 line-clamp-2 text-[11px] leading-relaxed text-text-muted">
          {server.description}
        </p>
      </div>
    </button>
  );
}

function InstallPanel({
  server,
  installation,
  onClose,
}: {
  server: McpServer;
  installation: McpInstallation | undefined;
  onClose: () => void;
}) {
  const install = useInstallMcp();
  const uninstall = useUninstallMcp();
  const figmaStart = useFigmaOauthStart();
  const googleStart = useGoogleOauthStart();
  const [apiKey, setApiKey] = useState("");
  const [serverUrl, setServerUrl] = useState("");
  const [token, setToken] = useState("");
  const [error, setError] = useState<string | null>(null);

  const isConnected = installation?.status === "connected";
  const isFigma = server.key === "figma";
  const isGoogle = googleServerKeys.has(server.key);

  const startFigmaOauth = async () => {
    setError(null);
    try {
      const result = await figmaStart.mutateAsync(figmaRedirectUri());
      window.location.href = result.data.authorize_url;
    } catch {
      setError("Figma OAuth is not configured on this environment.");
    }
  };

  const startGoogleOauth = async () => {
    setError(null);
    try {
      const result = await googleStart.mutateAsync({
        redirect_uri: googleRedirectUri(),
        provider_key: server.key,
      });
      window.location.href = result.data.authorize_url;
    } catch {
      setError("Google OAuth is not configured on this environment.");
    }
  };

  const installWithApiKey = async () => {
    setError(null);
    try {
      await install.mutateAsync({
        serverKey: server.key,
        credentials: { api_key: apiKey.trim() },
      });
      setApiKey("");
    } catch {
      setError("Installation failed. Check the API key and try again.");
    }
  };

  const installCustom = async () => {
    setError(null);
    try {
      await install.mutateAsync({
        serverKey: server.key,
        server_url: serverUrl.trim(),
        credentials: token.trim() ? { token: token.trim() } : { token: "" },
      });
      setServerUrl("");
      setToken("");
    } catch {
      setError("Installation failed. Check the server URL and try again.");
    }
  };

  return (
    <div className="space-y-5 px-5 py-4">
      <div className="flex items-center gap-3">
        <McpLogo slug={server.logo_slug} name={server.name} category={server.category} size="lg" />
        <div>
          <h3 className="flex items-center gap-1.5 text-sm font-bold text-text">
            {server.name}
            {server.featured && <Star size={12} className="fill-warning text-warning" />}
          </h3>
          <p className="text-[11px] capitalize text-text-muted">{server.category}</p>
        </div>
      </div>

      <p className="text-xs leading-relaxed text-text-secondary">{server.description}</p>

      {server.server_url && (
        <p className="flex items-center gap-1.5 text-[11px] text-text-muted">
          <ExternalLink size={11} />
          Remote MCP server: <span className="truncate text-text-secondary">{server.server_url}</span>
        </p>
      )}

      {error && (
        <p className="rounded-md border border-danger/30 bg-danger/10 px-3 py-2 text-[11px] text-danger">
          {error}
        </p>
      )}

      {isConnected ? (
        <>
          <div className="space-y-1.5 text-xs">
            {installation?.connected_account && (
              <div className="flex justify-between">
                <span className="text-text-muted">Account</span>
                <span className="text-text">{installation.connected_account}</span>
              </div>
            )}
            <div className="flex justify-between">
              <span className="text-text-muted">Installed</span>
              <span className="text-text">{formatRelative(installation!.inserted_at)}</span>
            </div>
            {installation?.settings.server_url && (
              <div className="flex justify-between gap-3">
                <span className="text-text-muted">Server URL</span>
                <span className="truncate text-text">{installation.settings.server_url}</span>
              </div>
            )}
          </div>
          <div className="rounded-md border border-success/25 bg-success-muted px-3 py-2 text-[11px] text-success">
            <Check size={12} className="mr-1 inline" />
            Installed. Grant access to agents from each agent's profile.
          </div>
          <Button
            variant="danger"
            size="sm"
            className="w-full"
            loading={uninstall.isPending}
            onClick={() => uninstall.mutate(installation!.id, { onSuccess: onClose })}
          >
            <Trash2 size={13} /> Uninstall
          </Button>
        </>
      ) : isFigma ? (
        <Button
          size="sm"
          className="w-full"
          loading={figmaStart.isPending}
          onClick={startFigmaOauth}
        >
          <Plug size={13} /> Connect with Figma
        </Button>
      ) : isGoogle ? (
        <Button
          size="sm"
          className="w-full"
          loading={googleStart.isPending}
          onClick={startGoogleOauth}
        >
          <Plug size={13} /> Connect with Google
        </Button>
      ) : server.auth_kind === "api_key" ? (
        <div className="space-y-3">
          <Field label="API key" hint="Stored encrypted. Only used by agents you authorize.">
            <input
              className="mk-input"
              type="password"
              placeholder="sk-…"
              value={apiKey}
              onChange={(e) => setApiKey(e.target.value)}
            />
          </Field>
          <Button
            size="sm"
            className="w-full"
            loading={install.isPending}
            disabled={!apiKey.trim()}
            onClick={installWithApiKey}
          >
            <Plug size={13} /> Install {server.name}
          </Button>
        </div>
      ) : (
        <div className="space-y-3">
          <Field
            label="MCP server URL"
            required
            hint="URL of your self-hosted or remote MCP server (HTTP transport)."
          >
            <input
              className="mk-input"
              placeholder="https://mcp.example.com/mcp"
              value={serverUrl}
              onChange={(e) => setServerUrl(e.target.value)}
            />
          </Field>
          <Field label="Access token (optional)">
            <input
              className="mk-input"
              type="password"
              value={token}
              onChange={(e) => setToken(e.target.value)}
            />
          </Field>
          <Button
            size="sm"
            className="w-full"
            loading={install.isPending}
            disabled={!serverUrl.trim()}
            onClick={installCustom}
          >
            <Plug size={13} /> Install {server.name}
          </Button>
        </div>
      )}

      {server.auth_kind === "oauth2" && !isFigma && !isGoogle && !isConnected && (
        <p className="text-center text-[10px] text-text-muted">
          Native OAuth for {server.name} is coming soon. You can connect it today through a custom
          MCP server URL above.
        </p>
      )}
    </div>
  );
}

export function McpHubPage() {
  const { data, isLoading } = useMcpHub();
  const [search, setSearch] = useState("");
  const [category, setCategory] = useState("all");
  const [selectedKey, setSelectedKey] = useState<string | null>(null);

  const servers = useMemo(() => data?.data.servers ?? [], [data]);
  const installations = useMemo(() => data?.data.installations ?? [], [data]);

  const installationByServer = useMemo(() => {
    const map = new Map<string, McpInstallation>();
    installations.forEach((i) => map.set(i.server_key, i));
    return map;
  }, [installations]);

  const filtered = useMemo(() => {
    let list = servers;
    if (category !== "all") list = list.filter((s) => s.category === category);
    if (search) {
      const q = search.toLowerCase();
      list = list.filter(
        (s) => s.name.toLowerCase().includes(q) || (s.description ?? "").toLowerCase().includes(q),
      );
    }
    return list;
  }, [servers, category, search]);

  const featured = filtered.filter((s) => s.featured);
  const rest = filtered.filter((s) => !s.featured);
  const installedCount = installations.filter((i) => i.status === "connected").length;
  const selected = servers.find((s) => s.key === selectedKey) ?? null;

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-5">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-bold text-text">MCP Hub</h1>
            <p className="text-xs text-text-muted">
              Connect your tools, then decide which agent can use which. {installedCount} installed
              · {servers.length} available
            </p>
          </div>
          <SearchInput
            placeholder="Search servers…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-64"
          />
        </div>

        <div className="flex flex-wrap gap-1.5">
          {categories.map((c) => (
            <button
              key={c.key}
              onClick={() => setCategory(c.key)}
              className={cn(
                "rounded-full border px-3 py-1 text-[11px] font-medium transition-colors mk-focus-ring",
                category === c.key
                  ? "border-primary/50 bg-primary-muted text-primary-light"
                  : "border-border text-text-muted hover:text-text",
              )}
            >
              {c.label}
            </button>
          ))}
        </div>

        {isLoading ? (
          <SkeletonRows rows={6} />
        ) : (
          <>
            {featured.length > 0 && (
              <div className="space-y-2.5">
                <h2 className="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-widest text-text-muted">
                  <Star size={11} className="fill-warning text-warning" /> Featured
                </h2>
                <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
                  {featured.map((server) => (
                    <ServerCard
                      key={server.key}
                      server={server}
                      installation={installationByServer.get(server.key)}
                      selected={selectedKey === server.key}
                      onSelect={() => setSelectedKey(server.key)}
                    />
                  ))}
                </div>
              </div>
            )}

            {rest.length > 0 && (
              <div className="space-y-2.5">
                {featured.length > 0 && (
                  <h2 className="text-[11px] font-semibold uppercase tracking-widest text-text-muted">
                    All servers
                  </h2>
                )}
                <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
                  {rest.map((server) => (
                    <ServerCard
                      key={server.key}
                      server={server}
                      installation={installationByServer.get(server.key)}
                      selected={selectedKey === server.key}
                      onSelect={() => setSelectedKey(server.key)}
                    />
                  ))}
                </div>
              </div>
            )}

            {filtered.length === 0 && (
              <p className="py-12 text-center text-xs text-text-muted">
                No MCP server matches your search.
              </p>
            )}
          </>
        )}
      </div>

      <DetailPanel open={selected != null} onClose={() => setSelectedKey(null)} title="MCP Server">
        {selected && (
          <InstallPanel
            key={selected.key}
            server={selected}
            installation={installationByServer.get(selected.key)}
            onClose={() => setSelectedKey(null)}
          />
        )}
      </DetailPanel>
    </div>
  );
}
