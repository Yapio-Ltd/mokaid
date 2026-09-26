import { useTaskActionDecision } from "@/api/task-action-decision";
import type { TaskPendingApproval } from "@/api/types";
import {
  SiteDeliveryChoice,
  isSiteDeliveryChoice,
} from "@/components/approvals/site-delivery-choice";
import { Button } from "@/components/ui/button";

/** Only explicit external permissions or genuine questions belong here, never internal exports. */
export function TaskAgentRequest({
  taskId,
  request,
}: {
  taskId: string;
  request: TaskPendingApproval | null;
}) {
  if (!request || request.tool_name === "export_pdf") return null;
  return <PendingAgentRequest key={`${taskId}:${request.id}`} taskId={taskId} request={request} />;
}

function PendingAgentRequest({
  taskId,
  request,
}: {
  taskId: string;
  request: TaskPendingApproval;
}) {
  const decision = useTaskActionDecision();
  const siteDelivery = isSiteDeliveryChoice(request.input_payload);

  const answer = (value: "approved" | "rejected") => {
    if (decision.isPending) return;
    decision.mutate({ taskId, requestId: request.id, decision: value });
  };
  const chooseDelivery = (delivery: "html" | "webapp") => {
    if (decision.isPending) return;
    decision.mutate({ taskId, requestId: request.id, decision: "edited", payload: { delivery } });
  };

  if (decision.isSuccess) {
    return (
      <p role="status" className="text-xs text-text-secondary">
        Your answer was sent to the agent.
      </p>
    );
  }

  return (
    <section aria-label="Agent request" className="rounded-xl bg-surface-raised/50 px-4 py-3.5">
      <p className="text-[12px] font-semibold text-text">
        {siteDelivery ? "How should we deliver this site?" : "Permission to continue"}
      </p>
      {!siteDelivery && (
        <p className="mt-1.5 text-xs leading-relaxed text-text-secondary">
          {request.proposed_action}
        </p>
      )}
      <div className="mt-3">
        {siteDelivery ? (
          <SiteDeliveryChoice
            payload={request.input_payload}
            busy={decision.isPending}
            onChoose={chooseDelivery}
          />
        ) : (
          <div className="flex gap-2">
            <Button
              type="button"
              size="sm"
              loading={decision.isPending}
              onClick={() => answer("approved")}
            >
              Allow once
            </Button>
            <Button
              type="button"
              size="sm"
              variant="secondary"
              disabled={decision.isPending}
              onClick={() => answer("rejected")}
            >
              Skip action
            </Button>
          </div>
        )}
      </div>
      {decision.isError && (
        <p role="alert" className="mt-2 text-xs text-danger">
          Could not send your answer. Please try again.
        </p>
      )}
    </section>
  );
}
