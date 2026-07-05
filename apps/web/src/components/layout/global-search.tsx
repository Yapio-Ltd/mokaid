import { useEffect, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { Bot, CheckSquare, FolderKanban, Library, Search } from "lucide-react";
import { apiFetch } from "@/api/client";
import { useAuthStore } from "@/stores/auth-store";
import { cn } from "@/lib/cn";

interface SearchResults {
  tasks: Array<{ id: string; title: string; status: string }>;
  projects: Array<{ id: string; title: string; status: string }>;
  agents: Array<{ id: string; title: string; subtitle: string | null; kind: string }>;
  knowledge: Array<{ id: string; title: string; type: string }>;
}

const sections: Array<{
  key: keyof SearchResults;
  label: string;
  to: string;
  icon: typeof Search;
}> = [
  { key: "tasks", label: "Tasks", to: "/tasks", icon: CheckSquare },
  { key: "projects", label: "Projects", to: "/projects", icon: FolderKanban },
  { key: "agents", label: "Agents", to: "/agents", icon: Bot },
  { key: "knowledge", label: "Knowledge", to: "/knowledge", icon: Library },
];

export function GlobalSearch() {
  const [query, setQuery] = useState("");
  const [debounced, setDebounced] = useState("");
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();
  const workspaceId = useAuthStore((s) => s.workspaceId);

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(query.trim()), 250);
    return () => clearTimeout(timer);
  }, [query]);

  useEffect(() => {
    const onClickOutside = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", onClickOutside);
    return () => document.removeEventListener("mousedown", onClickOutside);
  }, []);

  const { data, isFetching } = useQuery({
    queryKey: ["global-search", workspaceId, debounced],
    enabled: debounced.length >= 2,
    queryFn: () =>
      apiFetch<{ data: SearchResults }>("/api/search", { params: { q: debounced } }),
  });

  const results = data?.data;
  const totalResults = results
    ? sections.reduce((sum, s) => sum + results[s.key].length, 0)
    : 0;

  const handleSelect = (to: string) => {
    setOpen(false);
    setQuery("");
    navigate({ to });
  };

  return (
    <div ref={containerRef} className="relative w-80 max-w-full">
      <div className="relative">
        <Search
          size={14}
          className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-text-muted"
        />
        <input
          className="mk-input h-9 pl-9"
          placeholder="Search agents, tasks, projects…"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            setOpen(true);
          }}
          onFocus={() => query.trim().length >= 2 && setOpen(true)}
        />
      </div>

      {open && debounced.length >= 2 && (
        <div className="absolute left-0 top-11 z-50 w-full overflow-hidden rounded-lg border border-border bg-surface-overlay shadow-lg">
          {isFetching && !results ? (
            <p className="px-3 py-4 text-center text-xs text-text-muted">Searching…</p>
          ) : totalResults === 0 ? (
            <p className="px-3 py-4 text-center text-xs text-text-muted">
              No results for “{debounced}”
            </p>
          ) : (
            <div className="max-h-[380px] overflow-y-auto py-1">
              {sections.map(({ key, label, to, icon: Icon }) => {
                const items = results?.[key] ?? [];
                if (items.length === 0) return null;
                return (
                  <div key={key}>
                    <p className="px-3 pb-1 pt-2 text-[10px] font-semibold uppercase tracking-widest text-text-muted">
                      {label}
                    </p>
                    {items.map((item) => (
                      <button
                        key={item.id}
                        onClick={() => handleSelect(to)}
                        className={cn(
                          "flex w-full items-center gap-2.5 px-3 py-2 text-left text-xs text-text-secondary transition-colors",
                          "hover:bg-surface-hover hover:text-text",
                        )}
                      >
                        <Icon size={13} className="shrink-0 text-text-muted" />
                        <span className="min-w-0 flex-1 truncate font-medium text-text">
                          {item.title}
                        </span>
                        <span className="shrink-0 text-[10px] capitalize text-text-muted">
                          {"subtitle" in item && item.subtitle
                            ? item.subtitle
                            : "status" in item
                              ? item.status.replace("_", " ")
                              : "type" in item
                                ? item.type
                                : ""}
                        </span>
                      </button>
                    ))}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
