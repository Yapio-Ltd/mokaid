import { useMemo, useState } from "react";
import { FileText, Library, Link as LinkIcon, Plus, StickyNote, File } from "lucide-react";
import { useAgents, useKnowledgeCategories, useKnowledgeItems } from "@/api/hooks";
import type { KnowledgeItem } from "@/api/types";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Avatar } from "@/components/ui/avatar";
import { DetailPanel } from "@/components/ui/detail-panel";
import { SearchInput } from "@/components/ui/search-input";
import { SkeletonRows } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/ui/empty-state";
import { cn } from "@/lib/cn";
import { formatBytes, formatRelative } from "@/lib/format";

const typeIcon = {
  document: FileText,
  link: LinkIcon,
  file: File,
  note: StickyNote,
};

const statusTone: Record<string, "success" | "warning" | "muted" | "danger" | "default"> = {
  published: "success",
  processing: "warning",
  draft: "muted",
  archived: "muted",
  failed: "danger",
};

export function KnowledgePage() {
  const [categoryId, setCategoryId] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const { data: itemsData, isLoading } = useKnowledgeItems(
    categoryId ? { category_id: categoryId } : {},
  );
  const { data: categoriesData } = useKnowledgeCategories();
  const { data: agentsData } = useAgents();

  const items = useMemo(() => {
    const list = itemsData?.data ?? [];
    if (!search) return list;
    const q = search.toLowerCase();
    return list.filter((i) => i.title.toLowerCase().includes(q));
  }, [itemsData, search]);

  const categories = categoriesData?.data ?? [];
  const agents = agentsData?.data ?? [];
  const selected: KnowledgeItem | null = items.find((i) => i.id === selectedId) ?? null;
  const usedByAgents = selected
    ? agents.filter((a) => selected.used_by_agent_ids.includes(a.id))
    : [];

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-5">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-bold text-text">Knowledge</h1>
            <p className="text-xs text-text-muted">
              Documents, links and notes your agents can learn from
            </p>
          </div>
          <Button>
            <Plus size={14} /> Add Knowledge
          </Button>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <button
            onClick={() => setCategoryId(null)}
            className={cn(
              "rounded-full border px-3 py-1.5 text-xs font-medium transition-colors",
              categoryId === null
                ? "border-primary/40 bg-primary-muted text-primary-light"
                : "border-border bg-surface text-text-muted hover:text-text",
            )}
          >
            All
          </button>
          {categories.map((category) => (
            <button
              key={category.id}
              onClick={() => setCategoryId(category.id)}
              className={cn(
                "flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-xs font-medium transition-colors",
                categoryId === category.id
                  ? "border-primary/40 bg-primary-muted text-primary-light"
                  : "border-border bg-surface text-text-muted hover:text-text",
              )}
            >
              <span
                className="h-2 w-2 rounded-full"
                style={{ backgroundColor: category.color ?? "#7c5cff" }}
              />
              {category.name}
              <span className="text-[10px] text-text-muted">{category.item_count}</span>
            </button>
          ))}
        </div>

        <SearchInput
          placeholder="Search knowledge…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="w-72"
        />

        {isLoading ? (
          <SkeletonRows rows={6} />
        ) : items.length === 0 ? (
          <EmptyState
            icon={<Library size={24} />}
            title="No knowledge items"
            description="Upload documents or add links your agents can use."
          />
        ) : (
          <div className="mk-card overflow-hidden">
            <table className="w-full text-left text-xs">
              <thead>
                <tr className="border-b border-border text-[11px] uppercase tracking-wide text-text-muted">
                  <th className="px-5 py-3 font-medium">Title</th>
                  <th className="px-3 py-3 font-medium">Category</th>
                  <th className="px-3 py-3 font-medium">Type</th>
                  <th className="px-3 py-3 font-medium">Status</th>
                  <th className="px-3 py-3 font-medium">Indexing</th>
                  <th className="px-5 py-3 font-medium">Updated</th>
                </tr>
              </thead>
              <tbody>
                {items.map((item) => {
                  const Icon = typeIcon[item.type] ?? FileText;
                  return (
                    <tr
                      key={item.id}
                      onClick={() => setSelectedId(item.id)}
                      className="cursor-pointer border-b border-border/50 transition-colors last:border-0 hover:bg-surface-hover"
                    >
                      <td className="px-5 py-3">
                        <span className="flex items-center gap-2.5 font-medium text-text">
                          <Icon size={15} className="shrink-0 text-text-muted" />
                          <span className="max-w-[280px] truncate">{item.title}</span>
                        </span>
                      </td>
                      <td className="px-3 py-3">
                        {item.category_name ? (
                          <span className="flex items-center gap-1.5 text-text-secondary">
                            <span
                              className="h-2 w-2 rounded-full"
                              style={{ backgroundColor: item.category_color ?? "#7c5cff" }}
                            />
                            {item.category_name}
                          </span>
                        ) : (
                          "·"
                        )}
                      </td>
                      <td className="px-3 py-3 capitalize text-text-secondary">{item.type}</td>
                      <td className="px-3 py-3">
                        <Badge tone={statusTone[item.status] ?? "default"}>{item.status}</Badge>
                      </td>
                      <td className="px-3 py-3">
                        <Badge tone={item.indexing_status === "indexed" ? "success" : "muted"}>
                          {item.indexing_status.replace("_", " ")}
                        </Badge>
                      </td>
                      <td className="px-5 py-3 text-text-muted">
                        {formatRelative(item.updated_at)}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <DetailPanel open={selected != null} onClose={() => setSelectedId(null)} title="Knowledge Item">
        {selected && (
          <div className="space-y-5 px-5 py-4">
            <div>
              <h3 className="text-sm font-bold text-text">{selected.title}</h3>
              <div className="mt-2 flex flex-wrap items-center gap-2">
                <Badge tone={statusTone[selected.status] ?? "default"}>{selected.status}</Badge>
                <Badge tone="muted" className="capitalize">
                  {selected.type}
                </Badge>
                {selected.tags.map((tag) => (
                  <Badge key={tag} tone="primary">
                    {tag}
                  </Badge>
                ))}
              </div>
            </div>

            <div className="space-y-1.5 text-xs">
              <div className="flex justify-between">
                <span className="text-text-muted">Category</span>
                <span className="text-text">{selected.category_name ?? "·"}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">Version</span>
                <span className="text-text">v{selected.version}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-text-muted">Visibility</span>
                <span className="capitalize text-text">{selected.visibility}</span>
              </div>
              {selected.file_size_bytes != null && (
                <div className="flex justify-between">
                  <span className="text-text-muted">Size</span>
                  <span className="text-text">{formatBytes(selected.file_size_bytes)}</span>
                </div>
              )}
              <div className="flex justify-between">
                <span className="text-text-muted">Created by</span>
                <span className="text-text">{selected.created_by_name ?? "·"}</span>
              </div>
              {selected.source_url && (
                <div className="flex justify-between gap-3">
                  <span className="text-text-muted">Source</span>
                  <a
                    href={selected.source_url}
                    target="_blank"
                    rel="noreferrer"
                    className="truncate text-primary-light hover:underline"
                  >
                    {selected.source_url}
                  </a>
                </div>
              )}
            </div>

            <div>
              <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                Used by Agents
              </p>
              <div className="space-y-2">
                {usedByAgents.length ? (
                  usedByAgents.map((agent) => (
                    <div key={agent.id} className="flex items-center gap-2.5">
                      <Avatar
                        name={agent.display_name}
                        size="sm"
                        isAi={agent.kind === "ai"}
                        color={agent.avatar_config?.primary_color}
                      />
                      <div className="min-w-0">
                        <p className="truncate text-xs font-medium text-text">
                          {agent.display_name}
                        </p>
                        <p className="text-[10px] text-text-muted">{agent.role_title}</p>
                      </div>
                    </div>
                  ))
                ) : (
                  <p className="text-xs text-text-muted">Not used by any agent yet.</p>
                )}
              </div>
            </div>
          </div>
        )}
      </DetailPanel>
    </div>
  );
}
