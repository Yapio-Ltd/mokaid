defmodule Mokaid.Audit do
  @moduledoc "Audit trail for sensitive actions."

  import Ecto.Query

  alias Mokaid.Audit.AuditLog
  alias Mokaid.Repo

  @doc """
  Records an audit event. `actor` may be a member struct, an agent struct,
  `:system`, or nil.
  """
  def log(workspace_id, actor, action, resource_type, resource_id, metadata \\ %{}) do
    {actor_type, actor_id, actor_name} = actor_info(actor)

    %AuditLog{}
    |> AuditLog.changeset(%{
      "workspace_id" => workspace_id,
      "actor_type" => actor_type,
      "actor_id" => actor_id,
      "actor_name" => actor_name,
      "action" => action,
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "metadata" => metadata
    })
    |> Repo.insert()
  end

  defp actor_info(%Mokaid.Members.Member{} = member) do
    name =
      case member do
        %{user: %{full_name: name}} -> name
        _ -> nil
      end

    {"member", member.id, name}
  end

  defp actor_info(%Mokaid.Agents.Agent{} = agent), do: {"agent", agent.id, agent.display_name}
  defp actor_info(:system), do: {"system", nil, "system"}
  defp actor_info(nil), do: {"system", nil, nil}

  def list_logs(workspace_id, limit \\ 100) do
    Repo.all(
      from l in AuditLog,
        where: l.workspace_id == ^workspace_id,
        order_by: [desc: l.occurred_at],
        limit: ^limit
    )
  end
end
