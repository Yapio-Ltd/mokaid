defmodule Mokaid.AI.RuntimePolicy do
  @moduledoc "Workspace consent and server-owned limits for managed execution."
  import Ecto.Query
  alias Mokaid.{Permissions, Repo}
  alias Mokaid.Workspaces.Workspace

  def payload(workspace_id) when is_binary(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      nil -> payload(nil)
      workspace -> payload(workspace)
    end
  end

  def payload(workspace) do
    policy = (workspace && workspace.managed_runtime_policy) || %{}
    config = Application.get_env(:mokaid, :managed_runtime, [])

    %{
      enabled:
        policy["enabled"] == true and not is_nil(workspace) and is_nil(workspace.deleted_at),
      data_policy_accepted: policy["data_policy_accepted"] == true,
      budget_cents_standard: 50,
      budget_cents_complex: 200,
      max_active_sessions: 4,
      verified_models: Keyword.get(config, :verified_models, [])
    }
  end

  def public(workspace_id) do
    p = payload(workspace_id)

    %{
      enabled: p.enabled,
      data_policy_accepted: p.data_policy_accepted,
      data_region: "US",
      zero_data_retention: false,
      max_active_sessions: p.max_active_sessions,
      standard_credits: Mokaid.Billing.Credits.cost_cents_to_credits(p.budget_cents_standard),
      complex_credits: Mokaid.Billing.Credits.cost_cents_to_credits(p.budget_cents_complex)
    }
  end

  def update(workspace_id, member, attrs) do
    with :ok <- Permissions.authorize(member, "workspace.update"),
         true <- member.workspace_id == workspace_id,
         true <-
           Enum.all?(Map.take(attrs, ["enabled", "data_policy_accepted"]), fn {_, v} ->
             is_boolean(v)
           end) do
      Repo.transaction(fn ->
        workspace =
          Repo.one(
            from w in Workspace,
              where: w.id == ^workspace_id and is_nil(w.deleted_at),
              lock: "FOR UPDATE"
          )

        if is_nil(workspace), do: Repo.rollback(:not_found)
        prior = workspace.managed_runtime_policy || %{}
        policy = Map.merge(prior, Map.take(attrs, ["enabled", "data_policy_accepted"]))

        policy =
          if attrs["data_policy_accepted"] == false,
            do: Map.put(policy, "enabled", false),
            else: policy

        if policy["enabled"] == true and policy["data_policy_accepted"] != true,
          do: Repo.rollback(:data_policy_required)

        policy =
          if attrs["data_policy_accepted"] == true do
            Map.merge(policy, %{
              "accepted_by_member_id" => member.id,
              "accepted_at" => DateTime.to_iso8601(DateTime.utc_now()),
              "policy_version" => "managed-us-v1"
            })
          else
            policy
          end

        Repo.update!(Ecto.Changeset.change(workspace, managed_runtime_policy: policy))
      end)
    else
      false -> {:error, :invalid_policy}
      error -> error
    end
  end
end
