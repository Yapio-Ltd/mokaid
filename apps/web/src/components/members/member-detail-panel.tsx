import { useEffect, useState } from "react";
import { Bot, Link2, Trash2 } from "lucide-react";
import type { Member } from "@/api/types";
import { useAgents, useLinkMemberAgent, useUpdateMember } from "@/api/hooks";
import { DetailPanel } from "@/components/ui/detail-panel";
import { StatusAvatar } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { formatDate, formatRelative } from "@/lib/format";

export function MemberDetailPanel({
  member,
  onClose,
  onViewAgent,
  canRemove = false,
  onRemove,
  removing = false,
}: {
  member: Member | null;
  onClose: () => void;
  onViewAgent: (agentId: string) => void;
  canRemove?: boolean;
  onRemove?: () => void;
  removing?: boolean;
}) {
  const [title, setTitle] = useState("");
  const updateMember = useUpdateMember();
  const linkAgent = useLinkMemberAgent();
  const { data: agentsData } = useAgents();
  const agents = agentsData?.data ?? [];

  const linkableAgents = agents.filter(
    (agent) =>
      (agent.kind === "human_linked" || agent.kind === "hybrid") &&
      (!agent.linked_member_id || agent.linked_member_id === member?.id),
  );

  useEffect(() => {
    setTitle(member?.title ?? "");
  }, [member?.id, member?.title]);

  const saveTitle = () => {
    if (!member || title === (member.title ?? "")) return;
    updateMember.mutate({ id: member.id, title: title.trim() || undefined });
  };

  const handleLinkAgent = (agentId: string) => {
    if (!member) return;
    linkAgent.mutate({ memberId: member.id, agentId });
  };

  return (
    <DetailPanel open={member != null} onClose={onClose} title="Member Profile">
      {member && (
        <div className="space-y-5 px-5 py-4">
          <div className="flex flex-col items-center gap-3 pt-2">
            <StatusAvatar
              name={member.full_name}
              size="xl"
              status={
                member.last_active_at &&
                Date.now() - new Date(member.last_active_at).getTime() < 600_000
                  ? "online"
                  : "offline"
              }
            />
            <div className="text-center">
              <h3 className="text-base font-bold text-text">{member.full_name}</h3>
              <p className="text-xs text-text-muted">{member.email}</p>
            </div>
            <div className="flex flex-wrap items-center justify-center gap-2">
              <Badge tone={member.role_name === "Owner" ? "primary" : "default"}>
                {member.role_name}
              </Badge>
              <Badge tone={member.status === "active" ? "success" : "muted"}>{member.status}</Badge>
            </div>
          </div>

          <div className="space-y-3">
            <label className="block space-y-1.5">
              <span className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                Job title
              </span>
              <input
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                onBlur={saveTitle}
                onKeyDown={(e) => e.key === "Enter" && saveTitle()}
                placeholder="e.g. Product Designer"
                className="mk-input h-9"
              />
            </label>

            <div className="space-y-1.5 text-xs">
              <div className="flex justify-between gap-4">
                <span className="text-text-muted">Team</span>
                <span className="text-right text-text">{member.team_name ?? "·"}</span>
              </div>
              <div className="flex justify-between gap-4">
                <span className="text-text-muted">Joined</span>
                <span className="text-text">{formatDate(member.joined_at)}</span>
              </div>
              <div className="flex justify-between gap-4">
                <span className="text-text-muted">Last active</span>
                <span className="text-text">{formatRelative(member.last_active_at)}</span>
              </div>
              <div className="flex justify-between gap-4">
                <span className="text-text-muted">MFA</span>
                <span className="text-text">{member.mfa_enabled ? "Enabled" : "Off"}</span>
              </div>
            </div>
          </div>

          <div className="space-y-2">
            <p className="text-[11px] font-semibold uppercase tracking-wide text-text-muted">
              Linked agent
            </p>
            {member.linked_agent_id ? (
              <div className="flex items-center justify-between gap-3 rounded-lg bg-surface-raised p-3">
                <div className="flex min-w-0 items-center gap-2.5">
                  <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-primary-muted text-primary-light">
                    <Bot size={15} />
                  </span>
                  <div className="min-w-0">
                    <p className="truncate text-xs font-semibold text-text">
                      {member.linked_agent_name}
                    </p>
                    <p className="text-[10px] text-text-muted">Human-linked agent</p>
                  </div>
                </div>
                <Button
                  size="sm"
                  variant="secondary"
                  onClick={() => onViewAgent(member.linked_agent_id!)}
                >
                  <Link2 size={13} /> View
                </Button>
              </div>
            ) : (
              <div className="space-y-2">
                <p className="text-xs text-text-muted">No agent linked yet.</p>
                {linkableAgents.length > 0 && (
                  <select
                    className="mk-input h-9 w-full"
                    defaultValue=""
                    onChange={(e) => {
                      if (e.target.value) handleLinkAgent(e.target.value);
                    }}
                    aria-label="Link an agent"
                  >
                    <option value="" disabled>
                      Link an agent…
                    </option>
                    {linkableAgents.map((agent) => (
                      <option key={agent.id} value={agent.id}>
                        {agent.display_name}
                      </option>
                    ))}
                  </select>
                )}
              </div>
            )}
          </div>

          {canRemove && onRemove && (
            <Button
              variant="danger"
              size="sm"
              className="w-full"
              loading={removing}
              onClick={onRemove}
            >
              <Trash2 size={13} />
              Remove from workspace
            </Button>
          )}
        </div>
      )}
    </DetailPanel>
  );
}
