import { useMemo, useRef, useState } from "react";
import { AnimatePresence } from "framer-motion";
import { MessageSquarePlus, Volume2, VolumeX } from "lucide-react";
import type { Agent, AgentChatSummary } from "@/api/types";
import { useAgentChats, useAgents } from "@/api/hooks";
import { Avatar } from "@/components/ui/avatar";
import { AgentLevelRing } from "@/components/agents/agent-level-ring";
import { ChatWindow } from "./chat-window";
import { FadeSlide } from "@/components/ui/motion";
import { useChatStore } from "@/stores/chat-store";
import { cn } from "@/lib/cn";

const MAX_HEADS = 5;

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
        "group relative rounded-full transition-transform duration-150 ease-spring hover:scale-110",
        active && "scale-105",
      )}
    >
      <span
        className={cn(
          "block rounded-full ring-2 ring-offset-2 ring-offset-bg transition-shadow",
          busy
            ? "ring-warning shadow-glow"
            : active
              ? "ring-primary"
              : "ring-border-strong group-hover:ring-primary",
        )}
      >
        {agent.kind === "ai" ? (
          <AgentLevelRing
            level={agent.level}
            xp={agent.xp}
            xpForNext={agent.xp_for_next_level}
            size="md"
            showBadge={false}
          >
            <Avatar name={agent.display_name} size="md" isAi />
          </AgentLevelRing>
        ) : (
          <Avatar name={agent.display_name} size="md" isAi={false} />
        )}
      </span>

      {/* Busy = visibly at work: pulsing ring on top of the avatar. */}
      {busy && (
        <span className="pointer-events-none absolute inset-0 animate-ping rounded-full ring-2 ring-warning/50" />
      )}

      {unread > 0 && (
        <span className="absolute -right-1 -top-1 flex h-[1.125rem] min-w-[1.125rem] items-center justify-center rounded-full bg-danger px-1 text-[10px] font-bold leading-none text-white shadow-sm">
          {unread > 9 ? "9+" : unread}
        </span>
      )}

      <span
        className={cn(
          "absolute -bottom-0.5 -right-0.5 h-3 w-3 rounded-full ring-2 ring-bg",
          busy
            ? "bg-warning"
            : agent.presence_status === "online"
              ? "bg-success"
              : "bg-text-disabled",
        )}
      />
    </button>
  );
}

export function FloatingChatDock() {
  const { data: chatsData } = useAgentChats();
  const { data: agentsData } = useAgents();

  const openChatIds = useChatStore((s) => s.openChatIds);
  const openChat = useChatStore((s) => s.openChat);
  const closeChat = useChatStore((s) => s.closeChat);
  const soundEnabled = useChatStore((s) => s.soundEnabled);
  const toggleSound = useChatStore((s) => s.toggleSound);

  const [pickerOpen, setPickerOpen] = useState(false);
  const pickerRef = useRef<HTMLDivElement>(null);

  const agents = useMemo(() => agentsData?.data ?? [], [agentsData]);
  const summaries = useMemo(() => chatsData?.data ?? [], [chatsData]);

  const agentById = useMemo(() => new Map(agents.map((a) => [a.id, a])), [agents]);
  const summaryByAgent = useMemo(
    () => new Map(summaries.map((s) => [s.agent_id, s])),
    [summaries],
  );

  // Heads = existing conversations (already sorted by recency) + open chats.
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
    <div className="pointer-events-none fixed bottom-4 right-4 z-40 flex items-end gap-3">
      {/* Open chat windows, oldest on the left. */}
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

      {/* Chat heads column */}
      <div className="pointer-events-auto relative flex flex-col items-center gap-3">
        {headIds.map((agentId) => {
          const agent = agentById.get(agentId);
          if (!agent) return null;
          const active = openChatIds.includes(agentId);
          return (
            <ChatHead
              key={agentId}
              agent={agent}
              summary={summaryByAgent.get(agentId)}
              active={active}
              onClick={() => (active ? closeChat(agentId) : openChat(agentId))}
            />
          );
        })}

        <button
          type="button"
          onClick={toggleSound}
          title={soundEnabled ? "Mute sounds" : "Unmute sounds"}
          className="rounded-full p-1.5 text-text-disabled transition-colors hover:text-text"
        >
          {soundEnabled ? <Volume2 size={14} /> : <VolumeX size={14} />}
        </button>

        <button
          type="button"
          onClick={() => setPickerOpen((open) => !open)}
          title="Chat with an AI employee"
          aria-label="Chat with an AI employee"
          className="flex h-12 w-12 items-center justify-center rounded-full bg-primary text-white shadow-glow transition-transform duration-150 ease-spring hover:scale-110"
        >
          <MessageSquarePlus size={20} />
        </button>

        {/* Agent picker */}
        {pickerOpen && (
          <div
            ref={pickerRef}
            className="absolute bottom-14 right-0 max-h-80 w-64 overflow-y-auto rounded-xl border border-border-strong bg-surface p-1.5 shadow-lg"
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
                <Avatar name={agent.display_name} size="sm" isAi={agent.kind === "ai"} />
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
      </div>
    </div>
  );
}
