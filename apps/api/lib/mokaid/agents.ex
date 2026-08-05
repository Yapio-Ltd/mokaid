defmodule Mokaid.Agents do
  @moduledoc "Agents: AI-only, human-linked and hybrid work actors."

  import Ecto.Query

  alias Mokaid.Agents.{Agent, AgentStatusEvent, Archetypes, DomainPacks, Progression}
  alias Mokaid.Agents.Workers.AgentBoostTrainingWorker
  alias Mokaid.Audit
  alias Mokaid.Billing
  alias Mokaid.Billing.Credits
  alias Mokaid.Realtime
  alias Mokaid.Repo

  # Public create/update must never accept progression or ownership fields.
  # linked_user_id may still be provided when creating a human_linked agent.
  @client_forbidden ~w(
    skills level xp xp_for_next_level missions_completed performance_score
    capabilities access_scope seat_index workspace_id created_by_member_id
    manager_agent_id current_task_id archived_at last_active_at
    ai_enabled control_mode status presence_status
  )

  @public_update_drop ~w(
    skills level xp xp_for_next_level missions_completed performance_score
    capabilities access_scope seat_index workspace_id created_by_member_id
    kind linked_user_id linked_member_id manager_agent_id
  )

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

  # Nine physical desk chairs (indices 0..8 in the web OFFICE_DESK_SLOTS array).
  @max_office_seats 9

  # Desk indices assigned first → last. Matches office-navdata OFFICE_DESK_SLOTS
  # sorted by camera-near (highest z / bottom of the isometric map) so new
  # agents fill the foreground first, then mid desks, then the lounge edge.
  # Indices are physical chair slots — do not reorder unless the GLB seats change.
  @seat_fill_order [8, 7, 6, 5, 4, 3, 2, 1, 0]

  # Compile-time guard: fill order must cover every seat exactly once.
  if length(@seat_fill_order) != @max_office_seats or
       Enum.sort(@seat_fill_order) != Enum.to_list(0..(@max_office_seats - 1)) do
    raise "seat_fill_order must be a permutation of 0..#{@max_office_seats - 1}"
  end

  def create_agent(workspace_id, attrs, created_by \\ nil) do
    attrs = stringify_attrs(attrs)
    archetype_key = attrs["archetype_key"] || "blank"
    boost_key = attrs["boost_key"]

    with {:ok, prepared, archetype, boost} <-
           Archetypes.build_create_attrs(sanitize_client_attrs(attrs), archetype_key, boost_key) do
      prepared =
        if blank?(prepared["avatar_asset_id"]) do
          case Mokaid.Assets3d.character_for_archetype(archetype.key) do
            %{id: id} -> Map.put(prepared, "avatar_asset_id", id)
            _ -> prepared
          end
        else
          prepared
        end

      result =
        Repo.transaction(fn ->
          # Same advisory lock as seat allocation — quota + seat stay consistent.
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [
            to_string(workspace_id)
          ])

          active = active_agent_count(workspace_id)
          limit = Billing.agent_limit(workspace_id)

          # At the limit, an untouched bootstrap placeholder steps aside so
          # the user's own first employee can take its desk.
          active =
            if active >= limit and release_bootstrap_placeholder(workspace_id) == :released,
              do: active - 1,
              else: active

          if active >= limit do
            Repo.rollback(:agent_limit_reached)
          end

          seat =
            case find_free_seat(workspace_id) do
              nil -> Repo.rollback(:office_full)
              s -> s
            end

          case %Agent{}
               |> Agent.create_changeset(
                 Map.merge(prepared, %{
                   "presence_status" => "online",
                   "seat_index" => seat,
                   "workspace_id" => workspace_id,
                   "created_by_member_id" => created_by && created_by.id
                 })
               )
               |> Repo.insert() do
            {:ok, agent} ->
              if boost do
                case Credits.charge_strict(workspace_id, boost.credits,
                       kind: "agent_boost",
                       agent_id: agent.id,
                       description: "Agent boost: #{boost.name}"
                     ) do
                  {:ok, _sub, _credits} -> agent
                  {:error, reason} -> Repo.rollback(reason)
                end
              else
                agent
              end

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)

      case result do
        {:ok, agent} ->
          if boost do
            Credits.broadcast_balance(workspace_id)

            %{
              "workspace_id" => workspace_id,
              "agent_id" => agent.id,
              "member_id" => created_by && created_by.id
            }
            |> AgentBoostTrainingWorker.new()
            |> Oban.insert()
          end

          # Reload: Oban :inline (tests) may have finished training already.
          agent = get_agent(workspace_id, agent.id) || agent

          Realtime.broadcast_workspace(workspace_id, "agent.created", %{agent_id: agent.id})
          {:ok, agent}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  The first AI employee every new workspace ships with (see
  `Mokaid.Workspaces.create_workspace/3`). Flagged as `bootstrap` in its
  capabilities so `create_agent/3` can silently replace it with the user's
  own first custom agent when the plan's agent limit is reached.
  """
  def create_bootstrap_agent(workspace_id) do
    with {:ok, agent} <-
           create_agent(workspace_id, %{
             "kind" => "ai",
             "display_name" => "Moka",
             "role_title" => "Generalist Assistant",
             "archetype_key" => "blank"
           }) do
      agent
      |> Agent.internal_changeset(%{
        "capabilities" => Map.put(agent.capabilities || %{}, "bootstrap", true)
      })
      |> Repo.update()
    end
  end

  # An untouched bootstrap placeholder (never ran a mission, no task in
  # flight) is archived to free its quota slot and desk. Returns :released
  # or :none.
  defp release_bootstrap_placeholder(workspace_id) do
    placeholder =
      Repo.one(
        from a in Agent,
          where: a.workspace_id == ^workspace_id and is_nil(a.archived_at),
          where: fragment("?->>'bootstrap' = 'true'", a.capabilities),
          where: a.missions_completed == 0 and is_nil(a.current_task_id),
          limit: 1
      )

    case placeholder do
      nil ->
        :none

      agent ->
        {:ok, _} =
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

        :released
    end
  end

  @doc """
  Snapshot for the head-start training page (poll fallback + initial hydrate).
  """
  def training_snapshot(%Agent{} = agent) do
    training = get_in(agent.capabilities || %{}, ["training"]) || %{}
    domain_pack = get_in(agent.capabilities || %{}, ["domain_pack"]) || %{}
    status = Map.get(training, "status")
    complete? = status == "complete" or (agent.status != "training" and status != "running")

    %{
      agent_id: agent.id,
      display_name: agent.display_name,
      status: agent.status,
      level: agent.level || 1,
      xp: agent.xp || 0,
      xp_for_next_level: agent.xp_for_next_level || Progression.xp_required(agent.level || 1),
      skills: agent.skills || [],
      avatar_asset_id: agent.avatar_asset_id,
      avatar_config: agent.avatar_config,
      role_title: agent.role_title,
      training: training,
      domain_pack: %{
        seeded_count: Map.get(domain_pack, "seeded_count", 0),
        pending_count: Map.get(domain_pack, "pending_count", 0),
        seed_status: Map.get(domain_pack, "seed_status"),
        skill_count: Map.get(domain_pack, "skill_count", 0),
        archetype: Map.get(domain_pack, "archetype")
      },
      complete?: complete?,
      target_level: Map.get(training, "target_level") || agent.level || 1
    }
  end

  @doc """
  Runs progressive boost training: level climb, optional L10 domain pack seed,
  then marks the agent idle/ready. Idempotent if already complete.
  """
  def run_boost_training(workspace_id, agent_id, opts \\ []) do
    case get_agent(workspace_id, agent_id) do
      nil ->
        {:cancel, :agent_not_found}

      %Agent{} = agent ->
        training = get_in(agent.capabilities || %{}, ["training"]) || %{}

        cond do
          Map.get(training, "status") == "complete" ->
            {:ok, agent}

          training == %{} ->
            {:cancel, :no_training}

          true ->
            do_run_boost_training(agent, training, opts)
        end
    end
  end

  # Options reach this module either as a keyword list (direct call) or as a
  # string-keyed map (deserialised from an Oban job payload). Keyword access
  # raises on the map form, so normalise the lookup in one place.
  defp fetch_opt(opts, key) when is_list(opts) do
    # Keyword keys are always atoms, so only the atom lookup applies here.
    Keyword.get(opts, key)
  end

  defp fetch_opt(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, to_string(key))
  end

  defp fetch_opt(_opts, _key), do: nil

  defp do_run_boost_training(%Agent{} = agent, training, opts) do
    target = Map.get(training, "target_level") || 1
    skill_bonus = Map.get(training, "skill_bonus") || 0
    boost_key = Map.get(training, "boost_key")
    archetype_key = Map.get(training, "archetype_key") || "blank"
    brief = Map.get(training, "knowledge_brief")
    suggested_mcp = Map.get(training, "suggested_mcp") || []
    # opts arrives as a keyword list from direct calls and as a string-keyed
    # map when Oban round-trips it through JSON. `opts[:member_id]` raises on
    # the latter, so read both shapes explicitly.
    member_id = fetch_opt(opts, :member_id)
    member = if member_id, do: Mokaid.Repo.get(Mokaid.Members.Member, member_id)

    current = agent.level || 1
    seed_base = Map.get(training, "base_skill_level") || skill_seed_base(agent)

    with {:ok, agent} <- climb_levels(agent, current, target, skill_bonus, seed_base),
         {:ok, agent} <-
           maybe_seed_domain_pack(agent, boost_key, archetype_key, brief, suggested_mcp, member),
         {:ok, agent} <- finalize_training(agent, target, skill_bonus, seed_base) do
      {:ok, agent}
    end
  end

  defp skill_seed_base(%Agent{skills: skills}) when is_list(skills) do
    case Enum.find(skills, &match?(%{"level" => level} when is_integer(level), &1)) do
      %{"level" => level} -> level
      _ -> 40
    end
  end

  defp skill_seed_base(_), do: 40

  defp climb_levels(agent, current, target, _skill_bonus, _seed_base) when current >= target do
    {:ok, agent}
  end

  defp climb_levels(agent, current, target, skill_bonus, seed_base) do
    delay = boost_training_step_ms(target)
    steps = max(target - 1, 1)

    Enum.reduce_while((current + 1)..target, {:ok, agent}, fn level, {:ok, acc} ->
      if delay > 0, do: Process.sleep(delay)

      progress = (level - 1) / steps
      skills = interpolate_skills(acc.skills || [], seed_base, skill_bonus, progress)
      xp = 0
      next = Progression.xp_required(level)

      caps =
        (acc.capabilities || %{})
        |> put_in(["training", "phase"], "leveling")
        |> put_in(["training", "current_level"], level)

      attrs = %{
        "level" => level,
        "xp" => xp,
        "xp_for_next_level" => next,
        "skills" => skills,
        "capabilities" => caps
      }

      case apply_internal_update(acc, attrs) do
        {:ok, updated} ->
          broadcast_training_progress(updated, %{
            phase: "leveling",
            level: level,
            target_level: target,
            skills: skills
          })

          {:cont, {:ok, updated}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp interpolate_skills(skills, seed_base, skill_bonus, progress) when is_list(skills) do
    final_bonus = trunc(skill_bonus * progress)

    Enum.map(skills, fn
      skill when is_map(skill) ->
        Map.put(skill, "level", min(seed_base + final_bonus, 100))

      other ->
        other
    end)
  end

  defp interpolate_skills(skills, _, _, _), do: skills

  defp maybe_seed_domain_pack(agent, "boost_l10", archetype_key, brief, suggested_mcp, member) do
    caps =
      (agent.capabilities || %{})
      |> put_in(["training", "phase"], "seeding")

    {:ok, agent} = apply_internal_update(agent, %{"capabilities" => caps})

    broadcast_training_progress(agent, %{
      phase: "seeding",
      level: agent.level,
      target_level: get_in(caps, ["training", "target_level"])
    })

    delay = boost_training_step_ms(10)
    if delay > 0, do: Process.sleep(min(delay, 2_000))

    {:ok, _count, updated} =
      DomainPacks.seed_for_agent(agent.workspace_id, agent,
        archetype_key: archetype_key,
        brief: brief,
        suggested_mcp: suggested_mcp,
        member: member
      )

    broadcast_training_progress(updated, %{
      phase: "seeding",
      level: updated.level,
      target_level: get_in(updated.capabilities || %{}, ["training", "target_level"]),
      domain_pack: get_in(updated.capabilities || %{}, ["domain_pack"])
    })

    {:ok, updated}
  end

  defp maybe_seed_domain_pack(agent, _boost_key, _archetype, _brief, _mcp, _member),
    do: {:ok, agent}

  defp finalize_training(agent, target, skill_bonus, seed_base) do
    skills = interpolate_skills(agent.skills || [], seed_base, skill_bonus, 1.0)
    xp = 0
    next = Progression.xp_required(target)

    caps =
      (agent.capabilities || %{})
      |> put_in(["training", "status"], "complete")
      |> put_in(["training", "phase"], "complete")
      |> put_in(["training", "completed_at"], DateTime.utc_now() |> DateTime.to_iso8601())
      |> put_in(["training", "current_level"], target)

    attrs = %{
      "level" => target,
      "xp" => xp,
      "xp_for_next_level" => next,
      "skills" => skills,
      "capabilities" => caps,
      "status" => "idle"
    }

    with {:ok, updated} <- apply_internal_update(agent, attrs) do
      Realtime.broadcast_workspace(updated.workspace_id, "agent.training_complete", %{
        agent_id: updated.id,
        agent_name: updated.display_name,
        level: updated.level,
        skills: updated.skills,
        domain_pack: get_in(updated.capabilities || %{}, ["domain_pack"]),
        training: get_in(updated.capabilities || %{}, ["training"])
      })

      Realtime.broadcast_workspace(updated.workspace_id, "agent.status_changed", %{
        agent_id: updated.id,
        status: "idle",
        presence_status: "online",
        current_task_id: updated.current_task_id
      })

      {:ok, updated}
    end
  end

  defp broadcast_training_progress(agent, extra) do
    Realtime.broadcast_workspace(
      agent.workspace_id,
      "agent.training_progress",
      %{
        agent_id: agent.id,
        agent_name: agent.display_name,
        level: agent.level,
        xp: agent.xp,
        xp_for_next_level: agent.xp_for_next_level,
        skills: agent.skills,
        status: agent.status,
        training: get_in(agent.capabilities || %{}, ["training"]),
        domain_pack: get_in(agent.capabilities || %{}, ["domain_pack"])
      }
      |> Map.merge(extra)
    )
  end

  defp boost_training_step_ms(target_level) do
    case Application.get_env(:mokaid, :boost_training_step_ms) do
      ms when is_integer(ms) and ms >= 0 ->
        ms

      _ ->
        total_ms =
          case target_level do
            3 -> 4_000
            5 -> 7_000
            10 -> 10_000
            n when is_integer(n) and n > 1 -> n * 1_000
            _ -> 4_000
          end

        div(total_ms, max(target_level - 1, 1))
    end
  end

  @doc "Next free desk in camera-near fill order, or :office_full."
  def next_free_seat(workspace_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [to_string(workspace_id)])

    case find_free_seat(workspace_id) do
      nil -> {:error, :office_full}
      seat -> {:ok, seat}
    end
  end

  @doc "Seat indices from closest-to-camera (foreground) to furthest (lounge)."
  def seat_fill_order, do: @seat_fill_order

  defp find_free_seat(workspace_id) do
    taken =
      from(a in Agent,
        where:
          a.workspace_id == ^workspace_id and is_nil(a.archived_at) and not is_nil(a.seat_index),
        select: a.seat_index
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.find(@seat_fill_order, &(not MapSet.member?(taken, &1)))
  end

  def active_agent_count(workspace_id) do
    from(a in Agent, where: a.workspace_id == ^workspace_id and is_nil(a.archived_at))
    |> Repo.aggregate(:count)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp sanitize_client_attrs(attrs) do
    Map.drop(attrs, @client_forbidden ++ Enum.map(@client_forbidden, &String.to_atom/1))
  end

  defp stringify_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  def update_agent(%Agent{} = agent, attrs) do
    attrs =
      attrs
      |> stringify_attrs()
      |> Map.drop(@public_update_drop ++ Enum.map(@public_update_drop, &String.to_atom/1))

    result =
      agent
      |> Agent.update_changeset(Map.put(attrs, "workspace_id", agent.workspace_id))
      |> Repo.update()

    with {:ok, updated} <- result do
      Realtime.broadcast_workspace(agent.workspace_id, "agent.updated", %{agent_id: updated.id})
      {:ok, updated}
    end
  end

  @doc """
  Internal update used by progression and skill learning — may write level,
  XP, skills and capabilities that clients cannot set.
  """
  def apply_internal_update(%Agent{} = agent, attrs) do
    attrs = stringify_attrs(attrs)

    result =
      agent
      |> Agent.internal_changeset(Map.put(attrs, "workspace_id", agent.workspace_id))
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
    limit = Billing.agent_limit(workspace_id)

    %{
      total: Repo.aggregate(base, :count),
      ai: Repo.aggregate(where(base, [a], a.kind == "ai"), :count),
      human_linked: Repo.aggregate(where(base, [a], a.kind == "human_linked"), :count),
      hybrid: Repo.aggregate(where(base, [a], a.kind == "hybrid"), :count),
      active: Repo.aggregate(where(base, [a], a.status in ["active", "busy"]), :count),
      offline: Repo.aggregate(where(base, [a], a.status == "offline"), :count),
      limit: limit
    }
  end
end
