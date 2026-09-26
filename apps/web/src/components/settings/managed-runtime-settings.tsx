import { useState } from "react";
import type { ManagedRuntimePolicy } from "@mokaid/shared-types";
import { useRuntimePolicy, useUpdateRuntimePolicy } from "@/api/runtime-policy";
import { useAuthStore } from "@/stores/auth-store";
import { Button } from "@/components/ui/button";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";

function RuntimePolicyForm({
  policy,
  canEdit,
}: {
  policy: ManagedRuntimePolicy;
  canEdit: boolean;
}) {
  const [enabled, setEnabled] = useState(policy.enabled);
  const [consent, setConsent] = useState(policy.data_policy_accepted);
  const update = useUpdateRuntimePolicy();
  const dirty = enabled !== policy.enabled || consent !== policy.data_policy_accepted;
  const save = () => update.mutate({ enabled, data_policy_accepted: consent });

  return (
    <div className="space-y-4">
      <p className="text-xs text-text-secondary">
        Let Mokaid choose managed execution for tasks that need research, tools or several
        teammates. Your agents keep their permissions and approval rules.
      </p>
      <label className="flex items-start gap-3 text-xs text-text">
        <input
          type="checkbox"
          className="mt-0.5 accent-primary"
          checked={consent}
          disabled={!canEdit || update.isPending}
          onChange={(event) => {
            setConsent(event.target.checked);
            if (!event.target.checked) setEnabled(false);
          }}
        />
        <span>
          I authorize the task content and necessary files to be processed and stored by OpenAI in
          the United States. Zero data retention is not available for this service.
        </span>
      </label>
      <label className="flex items-center justify-between gap-3 text-xs font-medium text-text">
        Enable managed task execution
        <input
          type="checkbox"
          role="switch"
          className="accent-primary"
          checked={enabled}
          disabled={!canEdit || !consent || update.isPending}
          onChange={(event) => setEnabled(event.target.checked)}
        />
      </label>
      <p className="text-[11px] text-text-muted">
        Mission allowances: {policy.standard_credits.toLocaleString()} credits for standard work and{" "}
        {policy.complex_credits.toLocaleString()} for complex work, shared by all contributors.
      </p>
      {!canEdit && (
        <p className="text-xs text-text-muted">
          Only a workspace administrator can change this setting.
        </p>
      )}
      {update.isError && (
        <p role="alert" className="text-xs text-danger">
          {update.error instanceof Error
            ? update.error.message
            : "The setting could not be saved. Try again."}
        </p>
      )}
      {update.isSuccess && !dirty && (
        <p role="status" className="text-xs text-success">
          Managed execution settings saved.
        </p>
      )}
      {canEdit && (
        <Button
          type="button"
          variant="secondary"
          disabled={!dirty || (enabled && !consent)}
          loading={update.isPending}
          onClick={save}
        >
          Save execution settings
        </Button>
      )}
    </div>
  );
}

export function ManagedRuntimeSettings() {
  const workspaceId = useAuthStore((state) => state.workspaceId);
  const query = useRuntimePolicy();
  return (
    <Card>
      <CardHeader>
        <CardTitle>Managed task execution</CardTitle>
      </CardHeader>
      <CardBody>
        {query.isPending ? (
          <p className="text-xs text-text-muted">Loading execution settings…</p>
        ) : query.isError ? (
          <div className="space-y-2">
            <p role="alert" className="text-xs text-danger">
              Execution settings are unavailable. No settings have been changed.
            </p>
            <Button variant="secondary" size="sm" onClick={() => void query.refetch()}>
              Try again
            </Button>
          </div>
        ) : (
          query.data && (
            <RuntimePolicyForm
              key={workspaceId}
              policy={query.data.data}
              canEdit={query.data.meta?.can_update === true}
            />
          )
        )}
      </CardBody>
    </Card>
  );
}
