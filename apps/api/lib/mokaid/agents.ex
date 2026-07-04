defmodule Mokaid.Agents do
  @moduledoc "Agents: AI-only, human-linked and hybrid work actors."

  import Ecto.Query

  alias Mokaid.Agents.{Agent, AgentStatusEvent}
  alias Mokaid.Audit
  alias Mokaid.Realtime
  alias Mokaid.Repo

  def get_agent(workspace_id, id) do
    Repo.one(
      from a in Agent,
        where: a.workspace_id == ^workspace_id and a.id == ^id,
        preload: [:linked_user, linked_member: :user]
    )
  end

  def list_agents(workspace_id, filters \\ %{}) do
    from(a in Agent,
      where: a.workspace_id == ^workspace_id and is_nil(a.archived_at),
      preload: [:linked_user, linked_member: :user],
      order_by: [asc: a.inserted_at]
    )
    |> maybe_filter(:kind, filters["kind"])
    |> maybe_filter(:status, filters["status"])
    |> maybe_filter(:department, filters["department"])
    |> Repo.all()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [a], field(a, ^field) == ^value)

  def create_agent(workspace_id, attrs, created_by \\ nil) do
    result =
      %Agent{}
      |> Agent.changeset(
        Map.merge(attrs, %{
          "workspace_id" => workspace_id,
          "created_by_member_id" => created_by && created_by.id
        })
      )
      |> Repo.insert()

    with {:ok, agent} <- result do
      Realtime.broadcast_workspace(workspace_id, "agent.created", %{agent_id: agent.id})
      {:ok, agent}
    end
  end

  def update_agent(%Agent{} = agent, attrs) do
    result =
      agent
      |> Agent.changeset(Map.put(attrs, "workspace_id", agent.workspace_id))
      |> Repo.update()

    with {:ok, updated} <- result do
      Realtime.broadcast_workspace(agent.workspace_id, "agent.updated", %{agent_id: updated.id})
      {:ok, updated}
    end
  end

  def archive_agent(%Agent{} = agent) do
    agent
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now(), status: "archived")
    |> Repo.update()
  end

  @doc "Transitions an agent's status, records the event, broadcasts realtime update."
  def change_status(%Agent{} = agent, new_status, opts \\ []) do
    Repo.transaction(fn ->
      {:ok, updated} =
        agent
        |> Agent.status_changeset(%{
          "status" => new_status,
          "current_task_id" =>
            Keyword.get(opts, :current_task_id, agent.current_task_id),
          "last_active_at" => DateTime.utc_now()
        })
        |> Repo.update()

      %AgentStatusEvent{}
      |> AgentStatusEvent.changeset(%{
        "workspace_id" => agent.workspace_id,
        "agent_id" => agent.id,
        "from_status" => agent.status,
        "to_status" => new_status,
        "reason" => Keyword.get(opts, :reason)
      })
      |> Repo.insert!()

      Realtime.broadcast_workspace(agent.workspace_id, "agent.status_changed", %{
        agent_id: agent.id,
        status: new_status,
        presence_status: updated.presence_status,
        current_task_id: updated.current_task_id
      })

      updated
    end)
  end

  def link_user(%Agent{} = agent, user_id, member_id, actor) do
    if agent.kind == "ai" do
      {:error, :cannot_link_ai_agent}
    else
      result =
        agent
        |> Ecto.Changeset.change(linked_user_id: user_id, linked_member_id: member_id)
        |> Repo.update()

      with {:ok, updated} <- result do
        Audit.log(agent.workspace_id, actor, "agent.link_user", "agent", agent.id, %{
          user_id: user_id
        })

        Realtime.broadcast_workspace(agent.workspace_id, "agent.linked_user_changed", %{
          agent_id: agent.id,
          linked_user_id: user_id
        })

        {:ok, updated}
      end
    end
  end

  def unlink_user(%Agent{} = agent, actor) do
    if agent.kind == "human_linked" do
      {:error, :human_linked_requires_user}
    else
      result =
        agent
        |> Ecto.Changeset.change(linked_user_id: nil, linked_member_id: nil)
        |> Repo.update()

      with {:ok, updated} <- result do
        Audit.log(agent.workspace_id, actor, "agent.unlink_user", "agent", agent.id, %{})

        Realtime.broadcast_workspace(agent.workspace_id, "agent.linked_user_changed", %{
          agent_id: agent.id,
          linked_user_id: nil
        })

        {:ok, updated}
      end
    end
  end

  def counts(workspace_id) do
    base = from a in Agent, where: a.workspace_id == ^workspace_id and is_nil(a.archived_at)

    %{
      total: Repo.aggregate(base, :count),
      ai: Repo.aggregate(where(base, [a], a.kind == "ai"), :count),
      human_linked: Repo.aggregate(where(base, [a], a.kind == "human_linked"), :count),
      hybrid: Repo.aggregate(where(base, [a], a.kind == "hybrid"), :count),
      active:
        Repo.aggregate(where(base, [a], a.status in ["active", "busy"]), :count),
      offline: Repo.aggregate(where(base, [a], a.status == "offline"), :count)
    }
  end
end
