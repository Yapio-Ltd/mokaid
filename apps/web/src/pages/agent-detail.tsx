import { Link, useNavigate, useParams } from "@tanstack/react-router";
import { ArrowLeft, MessageCircle } from "lucide-react";
import { useAgent } from "@/api/hooks";
import { AgentProfileContent } from "@/components/agents/agent-profile-panel";
import { Button } from "@/components/ui/button";
import { useChatStore } from "@/stores/chat-store";

/** Deep-linkable, shareable full-page agent profile (/agents/:id). */
export function AgentDetailPage() {
  const { agentId } = useParams({ strict: false }) as { agentId: string };
  const navigate = useNavigate();
  const { data, isLoading } = useAgent(agentId);
  const openChat = useChatStore((s) => s.openChat);
  const agent = data?.data;

  return (
    <div className="h-full overflow-y-auto pb-10">
      <div className="mx-auto w-full max-w-2xl space-y-4">
        <div className="flex items-center justify-between gap-3">
          <Link
            to="/agents"
            className="inline-flex items-center gap-1.5 text-xs font-medium text-text-muted transition-colors hover:text-text"
          >
            <ArrowLeft size={13} /> Back to agents
          </Link>
          {agent && agent.kind === "ai" && (
            <Button size="sm" variant="secondary" onClick={() => openChat(agent.id)}>
              <MessageCircle size={13} /> Chat with {agent.display_name.split(" ")[0]}
            </Button>
          )}
        </div>

        {isLoading && (
          <div className="flex h-[40vh] items-center justify-center text-sm text-text-muted">
            Loading profile…
          </div>
        )}

        {!isLoading && !agent && (
          <div className="flex h-[40vh] flex-col items-center justify-center gap-3 text-center">
            <p className="text-sm text-text-muted">This agent does not exist (or was archived).</p>
            <Button size="sm" onClick={() => void navigate({ to: "/agents" })}>
              Back to agents
            </Button>
          </div>
        )}

        {agent && (
          <div className="rounded-2xl border border-border bg-surface/60 pt-2">
            <AgentProfileContent
              agent={agent}
              hideDeepLink
              onDeleted={() => void navigate({ to: "/agents" })}
            />
          </div>
        )}
      </div>
    </div>
  );
}
