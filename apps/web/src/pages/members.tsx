import { useMemo, useState } from "react";
import { Mail, Plus, Trash2, Users } from "lucide-react";
import {
  useAgents,
  useCancelInvite,
  useInviteMember,
  useMembers,
  useRemoveMember,
} from "@/api/hooks";
import { AgentProfilePanel } from "@/components/agents/agent-profile-panel";
import { MemberDetailPanel } from "@/components/members/member-detail-panel";
import { StatusAvatar } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { SkeletonRows } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/ui/empty-state";
import { cn } from "@/lib/cn";
import { formatDate } from "@/lib/format";
import { toast } from "@/stores/toast-store";
import { useAuthStore } from "@/stores/auth-store";

export function MembersPage() {
  const { data: membersData, isLoading } = useMembers();
  const { data: agentsData } = useAgents();
  const inviteMember = useInviteMember();
  const removeMember = useRemoveMember();
  const cancelInvite = useCancelInvite();

  const workspaceId = useAuthStore((s) => s.workspaceId);
  const workspaces = useAuthStore((s) => s.workspaces);
  const currentUser = useAuthStore((s) => s.user);
  const roleName =
    workspaces.find((w) => w.id === workspaceId)?.role_name ?? "Member";
  const canRemove = roleName === "Owner" || roleName === "Admin";

  const [inviteEmail, setInviteEmail] = useState("");
  const [selectedMemberId, setSelectedMemberId] = useState<string | null>(null);
  const [selectedAgentId, setSelectedAgentId] = useState<string | null>(null);

  const members = membersData?.data ?? [];
  const agents = agentsData?.data ?? [];
  const invites = membersData?.meta.pending_invites ?? [];

  const selectedMember = useMemo(
    () => members.find((m) => m.id === selectedMemberId) ?? null,
    [members, selectedMemberId],
  );
  const selectedAgent = useMemo(
    () => agents.find((a) => a.id === selectedAgentId) ?? null,
    [agents, selectedAgentId],
  );

  const sendInvite = () => {
    if (inviteEmail.includes("@")) {
      inviteMember.mutate({ email: inviteEmail }, { onSuccess: () => setInviteEmail("") });
    }
  };

  const handleRemoveMember = (memberId: string, label: string) => {
    if (!window.confirm(`Remove ${label} from this workspace?`)) return;
    removeMember.mutate(memberId, {
      onSuccess: () => {
        if (selectedMemberId === memberId) setSelectedMemberId(null);
        toast({ tone: "success", title: "Member removed", description: `${label} can no longer access this workspace.` });
      },
      onError: () =>
        toast({
          tone: "error",
          title: "Could not remove member",
          description: "You may not have permission, or this is the last owner.",
        }),
    });
  };

  const handleCancelInvite = (inviteId: string, email: string) => {
    if (!window.confirm(`Cancel the invitation to ${email}?`)) return;
    cancelInvite.mutate(inviteId, {
      onSuccess: () =>
        toast({ tone: "success", title: "Invitation canceled", description: email }),
      onError: () =>
        toast({
          tone: "error",
          title: "Could not cancel invitation",
          description: "Check your permissions and try again.",
        }),
    });
  };

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-5">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-bold text-text">Members</h1>
            <p className="text-xs text-text-muted">
              {members.length} members · {invites.length} pending invites
              {workspaces.find((w) => w.id === workspaceId)?.name
                ? ` · ${workspaces.find((w) => w.id === workspaceId)?.name}`
                : ""}
            </p>
          </div>
          <div className="flex items-center gap-2">
            <input
              type="email"
              value={inviteEmail}
              onChange={(e) => setInviteEmail(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && sendInvite()}
              placeholder="colleague@company.com"
              className="mk-input h-9 w-56"
            />
            <Button size="sm" onClick={sendInvite} loading={inviteMember.isPending}>
              <Plus size={13} /> Invite
            </Button>
          </div>
        </div>

        {isLoading ? (
          <SkeletonRows rows={6} />
        ) : members.length === 0 && invites.length === 0 ? (
          <EmptyState icon={<Users size={24} />} title="No members yet" />
        ) : (
          <div className="overflow-hidden rounded-lg bg-surface">
            <table className="w-full text-left text-xs">
              <thead>
                <tr className="text-[11px] uppercase tracking-wide text-text-muted">
                  <th className="px-5 py-3 font-medium">Member</th>
                  <th className="px-3 py-3 font-medium">Role</th>
                  <th className="px-3 py-3 font-medium">Team</th>
                  <th className="px-3 py-3 font-medium">Linked Agent</th>
                  <th className="px-3 py-3 font-medium">Status</th>
                  <th className="px-3 py-3 font-medium">Joined</th>
                  {canRemove && <th className="px-5 py-3 font-medium text-right">Actions</th>}
                </tr>
              </thead>
              <tbody>
                {members.map((member) => {
                  const isSelf = currentUser?.id === member.user_id;
                  const label = member.full_name || member.email || "this member";

                  return (
                    <tr
                      key={member.id}
                      onClick={() => {
                        setSelectedAgentId(null);
                        setSelectedMemberId(member.id);
                      }}
                      className={cn(
                        "cursor-pointer transition-colors hover:bg-surface-hover",
                        selectedMemberId === member.id &&
                          !selectedAgentId &&
                          "bg-primary-muted/40",
                      )}
                    >
                      <td className="px-5 py-3">
                        <div className="flex items-center gap-3">
                          <StatusAvatar
                            name={member.full_name}
                            size="sm"
                            status={
                              member.last_active_at &&
                              Date.now() - new Date(member.last_active_at).getTime() < 600_000
                                ? "online"
                                : "offline"
                            }
                          />
                          <div className="min-w-0">
                            <p className="truncate font-semibold text-text">{member.full_name}</p>
                            <p className="truncate text-[11px] text-text-muted">{member.email}</p>
                          </div>
                        </div>
                      </td>
                      <td className="px-3 py-3">
                        <Badge tone={member.role_name === "Owner" ? "primary" : "default"}>
                          {member.role_name}
                        </Badge>
                      </td>
                      <td className="px-3 py-3 text-text-secondary">{member.team_name ?? "·"}</td>
                      <td
                        className={cn(
                          "px-3 py-3 text-text-secondary",
                          member.linked_agent_id &&
                            "cursor-pointer hover:text-primary-light hover:underline",
                        )}
                        onClick={(e) => {
                          if (!member.linked_agent_id) return;
                          e.stopPropagation();
                          setSelectedMemberId(null);
                          setSelectedAgentId(member.linked_agent_id);
                        }}
                      >
                        {member.linked_agent_name ?? "·"}
                      </td>
                      <td className="px-3 py-3">
                        <Badge tone={member.status === "active" ? "success" : "muted"}>
                          {member.status}
                        </Badge>
                      </td>
                      <td className="px-3 py-3 text-text-muted">{formatDate(member.joined_at)}</td>
                      {canRemove && (
                        <td className="px-5 py-3 text-right">
                          {!isSelf && (
                            <button
                              type="button"
                              title="Remove member"
                              aria-label={`Remove ${label}`}
                              onClick={(e) => {
                                e.stopPropagation();
                                handleRemoveMember(member.id, label);
                              }}
                              disabled={removeMember.isPending}
                              className="inline-flex rounded-md p-1.5 text-text-muted transition-colors hover:bg-danger/10 hover:text-danger mk-focus-ring"
                            >
                              <Trash2 size={13} />
                            </button>
                          )}
                        </td>
                      )}
                    </tr>
                  );
                })}
                {invites.map((invite) => (
                  <tr key={invite.id} className="bg-bg-deep/40">
                    <td className="px-5 py-3">
                      <div className="flex items-center gap-3">
                        <span className="flex h-8 w-8 items-center justify-center rounded-full border border-dashed border-border-strong text-text-muted">
                          <Mail size={13} />
                        </span>
                        <p className="text-text-secondary">{invite.email}</p>
                      </div>
                    </td>
                    <td className="px-3 py-3">
                      <Badge tone="warning">Invitation pending</Badge>
                    </td>
                    <td className="px-3 py-3 text-text-muted">·</td>
                    <td className="px-3 py-3 text-text-muted">·</td>
                    <td className="px-3 py-3">
                      <Badge tone="muted">pending</Badge>
                    </td>
                    <td className="px-3 py-3 text-text-muted">
                      Expires {formatDate(invite.expires_at)}
                    </td>
                    {canRemove && (
                      <td className="px-5 py-3 text-right">
                        <button
                          type="button"
                          title="Cancel invitation"
                          aria-label={`Cancel invitation to ${invite.email}`}
                          onClick={() => handleCancelInvite(invite.id, invite.email)}
                          disabled={cancelInvite.isPending}
                          className="inline-flex rounded-md p-1.5 text-text-muted transition-colors hover:bg-danger/10 hover:text-danger mk-focus-ring"
                        >
                          <Trash2 size={13} />
                        </button>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {selectedAgent ? (
        <AgentProfilePanel agent={selectedAgent} onClose={() => setSelectedAgentId(null)} />
      ) : (
        <MemberDetailPanel
          member={selectedMember}
          onClose={() => setSelectedMemberId(null)}
          onViewAgent={(agentId) => {
            setSelectedMemberId(null);
            setSelectedAgentId(agentId);
          }}
          canRemove={canRemove && currentUser?.id !== selectedMember?.user_id}
          onRemove={() => {
            if (!selectedMember) return;
            handleRemoveMember(
              selectedMember.id,
              selectedMember.full_name || selectedMember.email || "this member",
            );
          }}
          removing={removeMember.isPending}
        />
      )}
    </div>
  );
}
