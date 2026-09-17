import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { Link } from "@tanstack/react-router";
import { MessageSquare, MoreHorizontal, Pencil } from "lucide-react";
import type { Agent } from "@/api/types";
import { useChatStore } from "@/stores/chat-store";

export function WorkforceAgentActions({
  agent,
  onSelect,
}: {
  agent: Agent;
  onSelect?: () => void;
}) {
  const openChat = useChatStore((state) => state.openChat);
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          className="wf-icon-button wf-row-menu"
          aria-label={`Actions for ${agent.display_name}`}
        >
          <MoreHorizontal size={17} />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content className="wf-menu" sideOffset={6} align="end">
          {onSelect && <DropdownMenu.Item onSelect={onSelect}>View overview</DropdownMenu.Item>}
          <DropdownMenu.Item
            disabled={agent.kind === "human_linked"}
            onSelect={() => openChat(agent.id)}
          >
            <MessageSquare size={14} /> Test agent
          </DropdownMenu.Item>
          <DropdownMenu.Item asChild>
            <Link to="/agents/$agentId" params={{ agentId: agent.id }}>
              <Pencil size={14} /> Edit agent
            </Link>
          </DropdownMenu.Item>
          {agent.status === "training" && (
            <DropdownMenu.Item asChild>
              <Link to="/agents/$agentId/training" params={{ agentId: agent.id }}>
                View training
              </Link>
            </DropdownMenu.Item>
          )}
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}
