defmodule Mokaid.Agents.Progression do
  @moduledoc """
  XP and levels for AI employees — the video-game layer on top of missions.

  Called from `Mokaid.AI.handle_completion/4` after every finished run:

    1. Awards XP weighted by the mission's real substance — deliverables
       produced, tools used, colleague consultations, token volume.
    2. Levels the agent up along a soft-exponential curve
       (`xp_for_next_level = 100 * level^1.5`, rounded), possibly several
       levels at once for a big mission.
    3. Recomputes `performance_score` (0-100) from mission volume, recent
       success and skill depth.
    4. Broadcasts `agent.level_up` so the UI can celebrate (ring pulse,
       toast) in real time.

  XP never goes down; failure costs nothing but earns nothing.
  """

  alias Mokaid.Agents
  alias Mokaid.Agents.Agent
  alias Mokaid.Realtime
  alias Mokaid.Repo

  @base_xp 20
  @xp_per_artifact 15
  @max_artifact_xp 60
  @xp_per_tool_call 3
  @max_tool_xp 30
  @xp_per_consultation 10
  @xp_per_10k_tokens 5
  @max_token_xp 25

  @doc "XP required to go from `level` to `level + 1`."
  def xp_required(level) when is_integer(level) and level >= 1 do
    round(100 * :math.pow(level, 1.5))
  end

  @doc """
  Records a completed mission: awards XP, levels up if earned, refreshes
  `performance_score`, and broadcasts `agent.level_up` when a level changed.

  Returns `{:ok, agent, leveled_up?}`.
  """
  def record_completion(%Agent{} = agent, output, token_usage \\ %{}) do
    gained = xp_for_mission(output || %{}, token_usage || %{})

    {level, xp, next} =
      apply_xp(agent.level || 1, (agent.xp || 0) + gained)

    missions = (agent.missions_completed || 0) + 1
    leveled_up? = level > (agent.level || 1)

    attrs = %{
      "level" => level,
      "xp" => xp,
      "xp_for_next_level" => next,
      "missions_completed" => missions,
      "performance_score" => performance_score(agent, missions, level)
    }

    with {:ok, updated} <- Agents.update_agent(agent, attrs) do
      if leveled_up? do
        Realtime.broadcast_workspace(agent.workspace_id, "agent.level_up", %{
          agent_id: agent.id,
          agent_name: agent.display_name,
          level: level,
          xp: xp,
          xp_for_next_level: next
        })
      end

      {:ok, updated, leveled_up?}
    end
  end

  @doc "XP awarded for one mission, from the run output and token usage."
  def xp_for_mission(output, token_usage) do
    artifacts = length(List.wrap(output["artifacts"] || []))
    tool_calls = length(List.wrap(output["tool_calls"] || []))
    consultations = length(List.wrap(output["consultations"] || []))
    tokens = token_usage["total_tokens"] || 0

    @base_xp +
      min(artifacts * @xp_per_artifact, @max_artifact_xp) +
      min(tool_calls * @xp_per_tool_call, @max_tool_xp) +
      consultations * @xp_per_consultation +
      min(div(tokens, 10_000) * @xp_per_10k_tokens, @max_token_xp)
  end

  # Rolls accumulated XP into levels; XP carries over between levels.
  defp apply_xp(level, xp) do
    required = xp_required(level)

    if xp >= required do
      apply_xp(level + 1, xp - required)
    else
      {level, xp, required}
    end
  end

  # 0-100 blend: mission volume (log-saturating), level depth and average
  # skill level. Simple, monotonic, cheap to recompute on every completion.
  defp performance_score(%Agent{} = agent, missions, level) do
    volume = min(:math.log2(missions + 1) * 12, 45)
    depth = min(level * 3, 30)

    skills = agent.skills || []

    skill_avg =
      case skills do
        [] ->
          0.0

        list ->
          levels = for s <- list, lvl = s["level"] || s[:level], is_number(lvl), do: lvl
          if levels == [], do: 0.0, else: Enum.sum(levels) / length(levels)
      end

    score = volume + depth + skill_avg * 0.25
    Decimal.from_float(Float.round(min(score, 100.0), 1))
  end

  @doc """
  Progression snapshot for the agent profile: level, XP bar, mission count
  and the most recent mission memories (agent-scoped knowledge notes).
  """
  def snapshot(%Agent{} = agent) do
    %{
      level: agent.level || 1,
      xp: agent.xp || 0,
      xp_for_next_level: agent.xp_for_next_level || xp_required(agent.level || 1),
      missions_completed: agent.missions_completed || 0,
      performance_score: agent.performance_score,
      specialty: get_in(agent.capabilities || %{}, ["learning", "specialty"]),
      recent_memories: recent_memories(agent)
    }
  end

  defp recent_memories(%Agent{} = agent) do
    import Ecto.Query

    Repo.all(
      from k in Mokaid.Knowledge.KnowledgeItem,
        where:
          k.workspace_id == ^agent.workspace_id and k.agent_id == ^agent.id and
            k.status == "published",
        order_by: [desc: k.inserted_at],
        limit: 5,
        select: %{id: k.id, title: k.title, inserted_at: k.inserted_at}
    )
  end
end
