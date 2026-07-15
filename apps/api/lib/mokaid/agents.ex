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

  @max_office_seats 9

  def create_agent(workspace_id, attrs, created_by \\ nil) do
    attrs =
      if blank?(attrs["avatar_asset_id"]) do
        case Mokaid.Assets3d.default_character() do
          %{id: id} -> Map.put(attrs, "avatar_asset_id", id)
          _ -> attrs
        end
      else
        attrs
      end

    result =
      Repo.transaction(fn ->
        case next_free_seat(workspace_id) do
          {:error, :office_full} ->
            Repo.rollback(:office_full)

          {:ok, seat} ->
            case %Agent{}
                 |> Agent.changeset(
                   Map.merge(
                     %{"presence_status" => "online", "seat_index" => seat},
                     Map.merge(attrs, %{
                       "workspace_id" => workspace_id,
                       "created_by_member_id" => created_by && created_by.id
                     })
                   )
                 )
                 |> Repo.insert() do
              {:ok, agent} -> agent
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)

    case result do
      {:ok, agent} ->
        Realtime.broadcast_workspace(workspace_id, "agent.created", %{agent_id: agent.id})
        {:ok, agent}

      {:error, :office_full} ->
        {:error, :office_full}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "First free desk index 0..8 for the workspace, or :office_full."
  def next_free_seat(workspace_id) do
    # Serialize seat picks per workspace (empty table does not lock any agent rows).
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [to_string(workspace_id)])

    taken =
      from(a in Agent,
        where: a.workspace_id == ^workspace_id and is_nil(a.archived_at) and not is_nil(a.seat_index),
        select: a.seat_index
      )
      |> Repo.all()
      |> MapSet.new()

    case Enum.find(0..(@max_office_seats - 1), &(not MapSet.member?(taken, &1))) do
      nil -> {:error, :office_full}
      seat -> {:ok, seat}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  def update_agent(%Agent{} = agent, attrs) do
    # Seat assignment is owned by create/archive — strip from generic PATCH.
    attrs = Map.drop(attrs, ["seat_index", :seat_index])

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
    result =
      agent
      |> Ecto.Changeset.change(
        archived_at: DateTime.utc_now(),
        status: "archived",
        seat_index: nil,
        office_activity: nil,
        office_poi_id: nil,
        office_slot_id: nil,
        office_activity_phase: nil,
        office_activity_ends_at: nil
      )
      |> Repo.update()

    with {:ok, updated} <- result do
      Realtime.broadcast_workspace(agent.workspace_id, "agent.updated", %{agent_id: updated.id})
      {:ok, updated}
    end
  end

  @doc "Set or clear a synchronized office POI activity for an idle agent."
  def set_office_activity(%Agent{} = agent, attrs) when is_map(attrs) do
    result =
      agent
      |> Agent.office_activity_changeset(attrs)
      |> Repo.update()

    with {:ok, updated} <- result do
      broadcast_office_activity(updated)
      {:ok, updated}
    end
  end

  def clear_office_activity(%Agent{} = agent) do
    set_office_activity(agent, %{
      "office_activity" => nil,
      "office_poi_id" => nil,
      "office_slot_id" => nil,
      "office_activity_phase" => nil,
      "office_activity_ends_at" => nil
    })
  end

  defp broadcast_office_activity(agent) do
    Realtime.broadcast_workspace(agent.workspace_id, "agent.office_activity", %{
      agent_id: agent.id,
      office_activity: agent.office_activity,
      office_poi_id: agent.office_poi_id,
      office_slot_id: agent.office_slot_id,
      office_activity_phase: agent.office_activity_phase,
      office_activity_ends_at: agent.office_activity_ends_at
    })
  end

  @doc "Transitions an agent's status, records the event, broadcasts realtime update."
  def change_status(%Agent{} = agent, new_status, opts \\ []) do
    result =
      Repo.transaction(fn ->
        {:ok, updated} =
          agent
          |> Agent.status_changeset(%{
            "status" => new_status,
            "current_task_id" => Keyword.get(opts, :current_task_id, agent.current_task_id),
            "last_active_at" => DateTime.utc_now()
          })
          |> Repo.update()

        updated =
          if new_status in ["busy", "blocked", "archived", "offline"] do
            {:ok, cleared} =
              updated
              |> Agent.office_activity_changeset(%{
                "office_activity" => nil,
                "office_poi_id" => nil,
                "office_slot_id" => nil,
                "office_activity_phase" => nil,
                "office_activity_ends_at" => nil
              })
              |> Repo.update()

            cleared
          else
            updated
          end

        %AgentStatusEvent{}
        |> AgentStatusEvent.changeset(%{
          "workspace_id" => agent.workspace_id,
          "agent_id" => agent.id,
          "from_status" => agent.status,
          "to_status" => new_status,
          "reason" => Keyword.get(opts, :reason)
        })
        |> Repo.insert!()

        updated
      end)

    # Broadcast only after commit. A client refetch triggered inside the
    # transaction can otherwise read the old status and remain stale.
    with {:ok, updated} <- result do
      Realtime.broadcast_workspace(updated.workspace_id, "agent.status_changed", %{
        agent_id: agent.id,
        status: new_status,
        presence_status: public_presence(updated),
        current_task_id: updated.current_task_id,
        office_activity: updated.office_activity,
        office_poi_id: updated.office_poi_id,
        office_slot_id: updated.office_slot_id,
        office_activity_phase: updated.office_activity_phase
      })

      {:ok, updated}
    end
  end

  # AI / hybrid agents are always present in the office. Only human-linked
  # teammates expose a real presence (online/away/offline).
  defp public_presence(%Agent{status: "archived"}), do: "offline"
  defp public_presence(%Agent{kind: "human_linked", presence_status: p}), do: p
  defp public_presence(%Agent{kind: kind}) when kind in ["ai", "hybrid"], do: "online"
  defp public_presence(%Agent{presence_status: p}), do: p || "online"

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
      active: Repo.aggregate(where(base, [a], a.status in ["active", "busy"]), :count),
      offline: Repo.aggregate(where(base, [a], a.status == "offline"), :count)
    }
  end
end
