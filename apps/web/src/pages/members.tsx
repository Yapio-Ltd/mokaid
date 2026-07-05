import { useMemo, useState } from "react";
import * as Tabs from "@radix-ui/react-tabs";
import { Check, Mail, Plus, Users, X } from "lucide-react";
import {
  useAgents,
  useCreateLeaveRequest,
  useInviteMember,
  useLeaveRequests,
  useMembers,
  useReviewLeaveRequest,
} from "@/api/hooks";
import { Dialog } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { Select } from "@/components/ui/select";
import { Textarea } from "@/components/ui/textarea";
import { AgentProfilePanel } from "@/components/agents/agent-profile-panel";
import { MemberDetailPanel } from "@/components/members/member-detail-panel";
import { StatusAvatar } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { SkeletonRows } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/ui/empty-state";
import { cn } from "@/lib/cn";
import { formatDate, formatRelative } from "@/lib/format";

const tabClass =
  "rounded-md px-4 py-2 text-xs font-medium text-text-muted transition-colors data-[state=active]:bg-surface-raised data-[state=active]:text-text";

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
  const { data: agentsData } = useAgents();
  const { data: leaveData } = useLeaveRequests();
  const inviteMember = useInviteMember();
  const reviewLeave = useReviewLeaveRequest();
  const createLeave = useCreateLeaveRequest();
  const [inviteEmail, setInviteEmail] = useState("");
  const [selectedMemberId, setSelectedMemberId] = useState<string | null>(null);
  const [selectedAgentId, setSelectedAgentId] = useState<string | null>(null);
  const [showLeaveModal, setShowLeaveModal] = useState(false);
  const [leaveType, setLeaveType] = useState("vacation");
  const [leaveStart, setLeaveStart] = useState("");
  const [leaveEnd, setLeaveEnd] = useState("");
  const [leaveReason, setLeaveReason] = useState("");

  const submitLeaveRequest = () => {
    if (!leaveStart || !leaveEnd) return;
    createLeave.mutate(
      {
        type: leaveType,
        start_at: new Date(leaveStart).toISOString(),
        end_at: new Date(leaveEnd).toISOString(),
        reason: leaveReason.trim() || undefined,
      },
      {
        onSuccess: () => {
          setShowLeaveModal(false);
          setLeaveStart("");
          setLeaveEnd("");
          setLeaveReason("");
        },
      },
    );
  };

  const members = membersData?.data ?? [];
  const agents = agentsData?.data ?? [];
  const invites = membersData?.meta.pending_invites ?? [];
  const leaveRequests = leaveData?.data ?? [];

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

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-5">
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
        <Tabs.List className="flex gap-1">
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
            <div className="overflow-hidden rounded-lg bg-surface">
              <table className="w-full text-left text-xs">
                <thead>
                  <tr className="text-[11px] uppercase tracking-wide text-text-muted">
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
                      onClick={() => {
                        setSelectedAgentId(null);
                        setSelectedMemberId(member.id);
                      }}
                      className={cn(
                        "cursor-pointer transition-colors hover:bg-surface-hover",
                        selectedMemberId === member.id && !selectedAgentId && "bg-primary-muted/40",
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
                      <td className="px-5 py-3 text-text-muted">{formatDate(member.joined_at)}</td>
                    </tr>
                  ))}
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
          <div className="flex justify-end">
            <Button size="sm" variant="secondary" onClick={() => setShowLeaveModal(true)}>
              <Plus size={13} /> Request Time Off
            </Button>
          </div>
          {leaveRequests.length === 0 ? (
            <EmptyState
              icon={<Users size={24} />}
              title="No time off requests"
              description="Requests from members and their linked agents will appear here."
            />
          ) : (
            leaveRequests.map((request) => (
              <div key={request.id} className="flex items-center gap-4 rounded-lg bg-surface p-4">
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
        />
      )}

      <Dialog
        open={showLeaveModal}
        onOpenChange={setShowLeaveModal}
        title="Request Time Off"
        footer={
          <>
            <Button variant="ghost" size="sm" onClick={() => setShowLeaveModal(false)}>
              Cancel
            </Button>
            <Button
              size="sm"
              loading={createLeave.isPending}
              disabled={!leaveStart || !leaveEnd}
              onClick={submitLeaveRequest}
            >
              Submit Request
            </Button>
          </>
        }
      >
        <div className="space-y-4">
          <Field label="Type">
            <Select
              value={leaveType}
              onValueChange={setLeaveType}
              options={[
                { value: "vacation", label: "Vacation" },
                { value: "sick_leave", label: "Sick leave" },
                { value: "remote_work", label: "Remote work" },
                { value: "other", label: "Other" },
              ]}
            />
          </Field>
          <div className="grid grid-cols-2 gap-3">
            <Field label="From" required>
              <input
                type="date"
                className="mk-input"
                value={leaveStart}
                onChange={(e) => setLeaveStart(e.target.value)}
              />
            </Field>
            <Field label="To" required>
              <input
                type="date"
                className="mk-input"
                value={leaveEnd}
                onChange={(e) => setLeaveEnd(e.target.value)}
              />
            </Field>
          </div>
          <Field label="Reason">
            <Textarea
              className="min-h-[64px]"
              placeholder="Optional note for your manager…"
              value={leaveReason}
              onChange={(e) => setLeaveReason(e.target.value)}
            />
          </Field>
        </div>
      </Dialog>
    </div>
  );
}
