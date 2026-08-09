import { useState } from "react";
import { Brain, ChevronDown, ChevronRight, Loader2, Trash2 } from "lucide-react";
import type { Agent } from "@/api/types";
import { useDeleteKnowledgeItem, useKnowledgeItem, useKnowledgeItems } from "@/api/hooks";
import { MarkdownView } from "@/components/ui/markdown-view";
import { formatRelative } from "@/lib/format";
import { toast } from "@/stores/toast-store";

function MemoryEntry({ id, title, insertedAt }: { id: string; title: string; insertedAt: string }) {
  const [open, setOpen] = useState(false);
  const { data, isLoading } = useKnowledgeItem(open ? id : null);
  const deleteItem = useDeleteKnowledgeItem();
  const body = data?.data.body;

  return (
    <div className="rounded-xl border border-border/60 bg-surface-raised/40">
      <div className="flex items-center gap-2 px-3 py-2.5">
        <button
          type="button"
          onClick={() => setOpen(!open)}
          className="flex min-w-0 flex-1 items-center gap-2 text-left"
        >
          {open ? (
            <ChevronDown size={13} className="shrink-0 text-text-muted" />
          ) : (
            <ChevronRight size={13} className="shrink-0 text-text-muted" />
          )}
          <span className="min-w-0 flex-1 truncate text-[12px] font-medium text-text">
            {title}
          </span>
          <span className="shrink-0 text-[10px] text-text-muted">
            {formatRelative(insertedAt)}
          </span>
        </button>
        <button
          type="button"
          aria-label="Forget this memory"
          disabled={deleteItem.isPending}
          onClick={() => {
            if (!window.confirm(`Forget "${title}"? The agent won't recall it anymore.`)) return;
            deleteItem.mutate(id, {
              onSuccess: () => toast({ tone: "success", title: "Memory forgotten" }),
            });
          }}
          className="shrink-0 rounded-md p-1 text-text-muted transition-colors hover:bg-danger/10 hover:text-danger"
        >
          {deleteItem.isPending ? (
            <Loader2 size={12} className="animate-spin" />
          ) : (
            <Trash2 size={12} />
          )}
        </button>
      </div>
      {open && (
        <div className="border-t border-border/50 px-3.5 py-3">
          {isLoading ? (
            <Loader2 size={13} className="animate-spin text-text-muted" />
          ) : body ? (
            <div className="max-h-64 overflow-y-auto">
              <MarkdownView markdown={body} />
            </div>
          ) : (
            <p className="text-[11px] text-text-muted">This memory has no readable content.</p>
          )}
        </div>
      )}
    </div>
  );
}

/**
 * Everything the agent learned on past missions (agent-scoped knowledge,
 * consolidated by the worker after each run). Visible and revocable — the
 * user stays in control of what their AI employee remembers.
 */
export function MemoriesSection({ agent }: { agent: Agent }) {
  const { data, isLoading } = useKnowledgeItems({ agent_id: agent.id });
  const memories = data?.data ?? [];

  return (
    <div className="space-y-3">
      <div>
        <p className="flex items-center gap-1.5 text-xs font-semibold text-text">
          <Brain size={13} className="text-primary-light" />
          Mission memories
        </p>
        <p className="mt-1 text-[11px] leading-relaxed text-text-muted">
          After each mission, {agent.display_name.split(" ")[0]} consolidates what worked, the
          pitfalls, and reusable facts. These memories feed future missions — remove any you
          don't want kept.
        </p>
      </div>

      {isLoading && <Loader2 size={14} className="animate-spin text-text-muted" />}

      {!isLoading && memories.length === 0 && (
        <p className="rounded-xl border border-dashed border-border px-3.5 py-4 text-center text-[11px] text-text-muted">
          No memories yet — they'll appear here after the first completed missions.
        </p>
      )}

      <div className="space-y-1.5">
        {memories.map((item) => (
          <MemoryEntry
            key={item.id}
            id={item.id}
            title={item.title}
            insertedAt={item.inserted_at}
          />
        ))}
      </div>
    </div>
  );
}
