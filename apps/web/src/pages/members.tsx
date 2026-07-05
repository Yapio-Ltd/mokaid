import { useState } from "react";
import * as Tabs from "@radix-ui/react-tabs";
import { Check, Mail, Plus, Users, X } from "lucide-react";
import {
  useInviteMember,
  useLeaveRequests,
  useMembers,
  useReviewLeaveRequest,
} from "@/api/hooks";
import { StatusAvatar } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { SkeletonRows } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/ui/empty-state";
import { formatDate, formatRelative } from "@/lib/format";

const tabClass =
  "border-b-2 border-transparent px-4 py-2.5 text-xs font-medium text-text-muted transition-colors data-[state=active]:border-primary data-[state=active]:text-text";

const leaveTypeLabel: Record<string, string> = {
  vacation: "Vacation",
  sick_leave: "Sick leave",
  remote_work: "Remote work",
  other: "Other",
};

const leaveStatusTone: Record<string, "warning" | "success" | "danger" | "muted"> = {
  pending: "warning",
  approved: "success",
  rejected: "danger",
  canceled: "muted",
};

export function MembersPage() {
  const { data: membersData, isLoading } = useMembers();
  const { data: leaveData } = useLeaveRequests();
  const inviteMember = useInviteMember();
  const reviewLeave = useReviewLeaveRequest();
  const [inviteEmail, setInviteEmail] = useState("");

  const members = membersData?.data ?? [];
  const invites = membersData?.meta.pending_invites ?? [];
  const leaveRequests = leaveData?.data ?? [];

  const sendInvite = () => {
    if (inviteEmail.includes("@")) {
      inviteMember.mutate({ email: inviteEmail }, { onSuccess: () => setInviteEmail("") });
    }
  };

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold text-text">Members</h1>
          <p className="text-xs text-text-muted">
            {members.length} members · {invites.length} pending invites
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

      <Tabs.Root defaultValue="members">
        <Tabs.List className="flex border-b border-border">
          <Tabs.Trigger value="members" className={tabClass}>
            Members
          </Tabs.Trigger>
          <Tabs.Trigger value="timeoff" className={tabClass}>
            Time Off & Requests
            {leaveRequests.some((r) => r.status === "pending") && (
              <span className="ml-1.5 rounded-full bg-warning-muted px-1.5 text-[10px] font-bold text-warning">
                {leaveRequests.filter((r) => r.status === "pending").length}
              </span>
            )}
          </Tabs.Trigger>
        </Tabs.List>

        <Tabs.Content value="members" className="pt-4">
          {isLoading ? (
            <SkeletonRows rows={6} />
          ) : members.length === 0 ? (
            <EmptyState icon={<Users size={24} />} title="No members yet" />
          ) : (
            <div className="mk-card overflow-hidden">
              <table className="w-full text-left text-xs">
                <thead>
                  <tr className="border-b border-border text-[11px] uppercase tracking-wide text-text-muted">
                    <th className="px-5 py-3 font-medium">Member</th>
                    <th className="px-3 py-3 font-medium">Role</th>
                    <th className="px-3 py-3 font-medium">Team</th>
                    <th className="px-3 py-3 font-medium">Linked Agent</th>
                    <th className="px-3 py-3 font-medium">Status</th>
                    <th className="px-5 py-3 font-medium">Joined</th>
                  </tr>
                </thead>
                <tbody>
                  {members.map((member) => (
                    <tr
                      key={member.id}
                      className="border-b border-border/50 transition-colors last:border-0 hover:bg-surface-hover"
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
                      <td className="px-3 py-3 text-text-secondary">
                        {member.linked_agent_name ?? "·"}
                      </td>
                      <td className="px-3 py-3">
                        <Badge tone={member.status === "active" ? "success" : "muted"}>
                          {member.status}
                        </Badge>
                      </td>
                      <td className="px-5 py-3 text-text-muted">{formatDate(member.joined_at)}</td>
                    </tr>
                  ))}
                  {invites.map((invite) => (
                    <tr key={invite.id} className="border-b border-border/50 bg-bg-deep/40 last:border-0">
                      <td className="px-5 py-3">
                        <div className="flex items-center gap-3">
                          <span className="flex h-8 w-8 items-center justify-center rounded-full border border-dashed border-border-strong text-text-muted">
                            <Mail size={13} />
                          </span>
                          <p className="text-text-secondary">{invite.email}</p>
                        </div>
                      </td>
                      <td className="px-3 py-3" colSpan={3}>
                        <Badge tone="warning">Invitation pending</Badge>
                      </td>
                      <td className="px-3 py-3 text-text-muted" colSpan={2}>
                        Expires {formatDate(invite.expires_at)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Tabs.Content>

        <Tabs.Content value="timeoff" className="space-y-3 pt-4">
          {leaveRequests.length === 0 ? (
            <EmptyState
              icon={<Users size={24} />}
              title="No time off requests"
              description="Requests from members and their linked agents will appear here."
            />
          ) : (
            leaveRequests.map((request) => (
              <div key={request.id} className="mk-card flex items-center gap-4 p-4">
                <StatusAvatar name={request.member_name} size="md" />
                <div className="min-w-0 flex-1">
                  <p className="text-xs font-semibold text-text">
                    {request.member_name}
                    <span className="ml-2 font-normal text-text-muted">
                      {leaveTypeLabel[request.type] ?? request.type}
                    </span>
                  </p>
                  <p className="text-[11px] text-text-muted">
                    {formatDate(request.start_at)} → {formatDate(request.end_at)}
                    {request.reason && ` · ${request.reason}`}
                  </p>
                  <p className="text-[10px] text-text-muted">
                    Requested {formatRelative(request.inserted_at)}
                    {request.reviewed_by_name && ` · reviewed by ${request.reviewed_by_name}`}
                  </p>
                </div>
                <Badge tone={leaveStatusTone[request.status] ?? "default"}>{request.status}</Badge>
                {request.status === "pending" && (
                  <div className="flex gap-1.5">
                    <Button
                      size="sm"
                      variant="secondary"
                      onClick={() => reviewLeave.mutate({ id: request.id, decision: "approve" })}
                    >
                      <Check size={13} /> Approve
                    </Button>
                    <Button
                      size="sm"
                      variant="danger"
                      onClick={() => reviewLeave.mutate({ id: request.id, decision: "reject" })}
                    >
                      <X size={13} /> Reject
                    </Button>
                  </div>
                )}
              </div>
            ))
          )}
        </Tabs.Content>
      </Tabs.Root>
    </div>
  );
}
