import { useMemo, useRef, useState } from "react";
import { AnimatePresence } from "framer-motion";
import { MessageSquarePlus } from "lucide-react";
import type { Agent, AgentChatSummary } from "@/api/types";
import { useAgentChats, useAgents } from "@/api/hooks";
import { AgentAvatar } from "@/components/agents/agent-avatar";
import { agentRingOuterPx } from "@/components/agents/agent-level-ring";
import { ChatWindow } from "./chat-window";
import { FadeSlide } from "@/components/ui/motion";
import { useChatStore } from "@/stores/chat-store";
import { useUiStore } from "@/stores/ui-store";
import { cn } from "@/lib/cn";

const MAX_HEADS = 5;
const HEAD_SIZE = "md" as const;
const HEAD_RING_PX = agentRingOuterPx(HEAD_SIZE);

function ChatHead({
  agent,
  summary,
  active,
  onClick,
}: {
  agent: Agent;
  summary?: AgentChatSummary;
  active: boolean;
  onClick: () => void;
}) {
  const busy = agent.status === "busy" || agent.status === "active";
  const unread = summary?.unread_count ?? 0;

  return (
    <button
      type="button"
      onClick={onClick}
      title={agent.display_name}
      className={cn(
        "group relative z-10 inline-flex shrink-0 items-center justify-center transition-transform duration-150 ease-spring hover:scale-105",
        active && "scale-105",
      )}
      style={{ width: HEAD_RING_PX, height: HEAD_RING_PX }}
    >
      <span
        className="relative block [corner-shape:round]"
        style={{
          width: HEAD_RING_PX,
          height: HEAD_RING_PX,
          borderRadius: "50%",
          boxShadow: active
            ? "0 0 0 2px var(--mk-bg, #0b0b10), 0 0 0 3.5px color-mix(in srgb, var(--mk-primary-500, #7c5cff) 85%, transparent)"
            : undefined,
        }}
      >
        <AgentAvatar agent={agent} size={HEAD_SIZE} showBadge={false} />

        {/* Status dot — half on the XP track, half outside. */}
        <span
          className={cn(
            "pointer-events-none absolute z-20 h-2.5 w-2.5 ring-2 ring-bg [corner-shape:round]",
            busy
              ? "bg-warning"
              : agent.presence_status === "online"
                ? "bg-success"
                : "bg-text-disabled",
          )}
          style={{
            bottom: 2,
            right: 2,
            borderRadius: "50%",
            clipPath: "circle(50% at 50% 50%)",
            WebkitClipPath: "circle(50% at 50% 50%)",
          }}
        />

        {/* Busy: pulse glued to the circle — does not scale up and spill below. */}
        {busy && (
          <span
            className="pointer-events-none absolute inset-0 animate-[mk-avatar-busy-pulse_1.6s_ease-in-out_infinite] [corner-shape:round]"
            style={{ borderRadius: "50%" }}
            aria-hidden
          />
        )}
      </span>

      {unread > 0 && (
        <span
          className="absolute z-20 flex h-[1.125rem] min-w-[1.125rem] items-center justify-center bg-danger px-1 text-[10px] font-bold leading-none text-white shadow-sm [corner-shape:round]"
          style={{ borderRadius: "50%", top: -2, right: -2 }}
        >
          {unread > 9 ? "9+" : unread}
        </span>
      )}
    </button>
  );
}

export function FloatingChatDock() {
  const { data: chatsData } = useAgentChats();
  const { data: agentsData } = useAgents();

  const openChatIds = useChatStore((s) => s.openChatIds);
  const openChat = useChatStore((s) => s.openChat);
  const closeChat = useChatStore((s) => s.closeChat);
  const detailPanelOpen = useUiStore((s) => s.detailPanelCount > 0);

  const [pickerOpen, setPickerOpen] = useState(false);
  const pickerRef = useRef<HTMLDivElement>(null);

  const agents = useMemo(() => agentsData?.data ?? [], [agentsData]);
  const summaries = useMemo(() => chatsData?.data ?? [], [chatsData]);

  const agentById = useMemo(() => new Map(agents.map((a) => [a.id, a])), [agents]);
  const summaryByAgent = useMemo(
    () => new Map(summaries.map((s) => [s.agent_id, s])),
    [summaries],
  );

  const headIds = useMemo(() => {
    const ids = summaries.map((s) => s.agent_id);
    for (const id of openChatIds) if (!ids.includes(id)) ids.push(id);
    return ids.filter((id) => agentById.has(id)).slice(0, MAX_HEADS);
  }, [summaries, openChatIds, agentById]);

  const pickerAgents = useMemo(
    () =>
      agents
        .filter((a) => a.kind !== "human_linked" && a.status !== "archived")
        .sort((a, b) => a.display_name.localeCompare(b.display_name)),
    [agents],
  );

  if (agents.length === 0) return null;

  return (
    <>
      <div
        className={cn(
          "pointer-events-none fixed bottom-4 z-40 flex items-end gap-3 transition-[right] duration-300 ease-out",
          detailPanelOpen ? "right-[472px]" : "right-4",
        )}
      >
        <AnimatePresence>
          {openChatIds.map((agentId) => {
            const agent = agentById.get(agentId);
            return agent ? (
              <FadeSlide key={agentId} y={12}>
                <ChatWindow agent={agent} />
              </FadeSlide>
            ) : null;
          })}
        </AnimatePresence>

        <div className="pointer-events-auto relative flex flex-col items-center gap-1.5">
          {headIds.map((agentId, index) => {
            const agent = agentById.get(agentId);
            if (!agent) return null;
            const active = openChatIds.includes(agentId);
            return (
              <div key={agentId} className={cn(index > 0 && "-mt-1")}>
                <ChatHead
                  agent={agent}
                  summary={summaryByAgent.get(agentId)}
                  active={active}
                  onClick={() => (active ? closeChat(agentId) : openChat(agentId))}
                />
              </div>
            );
          })}

          <button
            type="button"
            onClick={() => setPickerOpen((open) => !open)}
            title="Chat with an AI employee"
            aria-label="Chat with an AI employee"
            className="mt-0.5 flex h-10 w-10 items-center justify-center rounded-full bg-primary text-white shadow-glow transition-transform duration-150 ease-spring hover:scale-110 [corner-shape:round]"
          >
            <MessageSquarePlus size={17} />
          </button>
        </div>
      </div>

      {pickerOpen && (
        <div
          ref={pickerRef}
          className="pointer-events-auto fixed bottom-6 left-1/2 z-50 max-h-80 w-72 -translate-x-1/2 overflow-y-auto rounded-xl border border-border-strong bg-surface p-1.5 shadow-xl"
        >
          <p className="px-2.5 py-1.5 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
            Your AI team
          </p>
          {pickerAgents.length === 0 && (
            <p className="px-2.5 pb-2 text-xs text-text-muted">
              No AI employees yet — hire one from the Agents page.
            </p>
          )}
          {pickerAgents.map((agent) => (
            <button
              key={agent.id}
              type="button"
              onClick={() => {
                openChat(agent.id);
                setPickerOpen(false);
              }}
              className="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors hover:bg-surface-hover"
            >
              <AgentAvatar agent={agent} size="sm" showRing={false} showBadge={false} />
              <span className="min-w-0 flex-1">
                <span className="block truncate text-[13px] font-medium text-text">
                  {agent.display_name}
                </span>
                <span className="block truncate text-[11px] text-text-muted">
                  {agent.role_title ?? "Generalist"}
                </span>
              </span>
              {(agent.status === "busy" || agent.status === "active") && (
                <span className="h-2 w-2 shrink-0 animate-pulse rounded-full bg-warning" />
              )}
            </button>
          ))}
        </div>
      )}
    </>
  );
}
