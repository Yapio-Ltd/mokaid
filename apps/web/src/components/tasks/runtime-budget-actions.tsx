import { useRef } from "react";
import { useExtendRuntimeBudget } from "@/api/runtime-budget";
import { Button } from "@/components/ui/button";
import { useAuthStore } from "@/stores/auth-store";

type Attempt = { credits: 500 | 2000; requestId: string };
const pendingAttempts = new Map<string, Attempt>();
function pendingAttempt(key: string): Attempt | null {
  try {
    const saved = JSON.parse(sessionStorage.getItem(key) || "null") as Attempt | null;
    if (saved && [500, 2000].includes(saved.credits) && typeof saved.requestId === "string")
      return saved;
  } catch {
    /* In-memory identity still protects retries if storage is unavailable. */
  }
  return pendingAttempts.get(key) ?? null;
}
function saveAttempt(key: string, value: Attempt | null) {
  if (value) pendingAttempts.set(key, value);
  else pendingAttempts.delete(key);
  try {
    if (value) sessionStorage.setItem(key, JSON.stringify(value));
    else sessionStorage.removeItem(key);
  } catch {
    /* Restricted browsers may disable sessionStorage. */
  }
}

/** Keep the same request identity until a failed or uncertain attempt resolves. */
export function RuntimeBudgetActions({ taskId, runId }: { taskId: string; runId: string }) {
  const workspaceId = useAuthStore((state) => state.workspaceId);
  const userId = useAuthStore((state) => state.user?.id);
  const key = `mokaid-runtime-budget:${workspaceId}:${userId}:${taskId}:${runId}`;
  return <BudgetAttempt key={key} storageKey={key} taskId={taskId} runId={runId} />;
}

function BudgetAttempt({
  storageKey: key,
  taskId,
  runId,
}: {
  storageKey: string;
  taskId: string;
  runId: string;
}) {
  const extend = useExtendRuntimeBudget();
  const attempt = useRef<Attempt | null>(pendingAttempt(key));
  const addCredits = async (credits: 500 | 2000) => {
    if (
      extend.isPending ||
      extend.isSuccess ||
      (attempt.current && attempt.current.credits !== credits)
    )
      return;
    attempt.current ??= { credits, requestId: crypto.randomUUID() };
    saveAttempt(key, attempt.current);
    try {
      await extend.mutateAsync({
        taskId,
        run_id: runId,
        request_id: attempt.current.requestId,
        additional_credits: credits,
      });
      // A request can succeed after this panel closes. Retire its identity even
      // after unmount so a later budget pause can create a new reservation.
      saveAttempt(key, null);
    } catch {
      // The mutation exposes its error; preserve the identity for a safe retry.
    }
  };
  return (
    <div className="space-y-2" aria-label="Continue with more credits">
      <p className="text-[11px] text-text-secondary">
        Reserve more workspace credits to continue this mission with the same team.
      </p>
      <div className="flex flex-wrap gap-2">
        {([500, 2000] as const).map((credits) => (
          <Button
            key={credits}
            type="button"
            size="sm"
            variant="secondary"
            disabled={
              extend.isPending ||
              extend.isSuccess ||
              (attempt.current !== null && attempt.current.credits !== credits)
            }
            onClick={() => addCredits(credits)}
          >
            {extend.isError && attempt.current?.credits === credits ? "Retry " : ""}+
            {credits.toLocaleString("en-US")} credits
          </Button>
        ))}
      </div>
      {extend.isPending && (
        <p role="status" className="text-xs text-text-muted">
          Updating the mission budget…
        </p>
      )}
      {extend.isSuccess && (
        <p role="status" className="text-xs text-success">
          Budget increased. The mission is resuming.
        </p>
      )}
      {extend.isError && (
        <p role="alert" className="text-xs text-danger">
          {extend.error instanceof Error
            ? extend.error.message
            : "The budget could not be updated."}{" "}
          Retry the same amount to check this request without reserving it twice.
        </p>
      )}
    </div>
  );
}
