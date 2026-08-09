defmodule Mokaid.AI.Workers.ScheduleWorker do
  @moduledoc """
  Minute cron sweep for agent automations: every due schedule becomes a
  regular Task assigned to its agent + an AI run — reusing the whole
  existing pipeline (per-agent serial queue, approvals, chat delivery).

  The per-agent queue in `Mokaid.AI.dispatch_next/2` already serialises
  work, so a schedule firing while the agent is busy simply queues.
  """

  use Oban.Worker, queue: :ai_dispatch, max_attempts: 1

  require Logger

  alias Mokaid.Agents
  alias Mokaid.AI.Schedules
  alias Mokaid.Tasks

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()

    now
    |> Schedules.due_schedules()
    |> Enum.each(&fire(&1, now))

    :ok
  end

  defp fire(schedule, now) do
    # Record first: a crash while launching must not re-fire every minute.
    {:ok, schedule} = Schedules.record_run(schedule, now)

    agent = Agents.get_agent(schedule.workspace_id, schedule.agent_id)

    cond do
      agent == nil or agent.archived_at != nil ->
        Logger.info("schedule_skipped_agent_gone schedule=#{schedule.id}")

      not agent.ai_enabled ->
        Logger.info("schedule_skipped_agent_disabled schedule=#{schedule.id}")

      true ->
        launch(schedule, agent)
    end
  rescue
    error ->
      Logger.warning("schedule_fire_failed schedule=#{schedule.id}: #{inspect(error)}")
      :ok
  end

  defp launch(schedule, agent) do
    date = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")

    with {:ok, task} <-
           Tasks.create_task(schedule.workspace_id, %{
             "title" => "#{schedule.name} — #{date}",
             "description" => schedule.prompt,
             "assigned_agent_id" => agent.id,
             "priority" => "medium",
             "metadata" => %{
               "source" => "automation",
               "schedule_id" => schedule.id,
               "schedule_name" => schedule.name,
               "instruction" => schedule.prompt,
               # Deliver the result into the agent's DM thread like
               # chat-born missions (maybe_deliver_to_chat).
               "chat_agent_id" => agent.id
             }
           }),
         {:ok, _run} <- Mokaid.AI.start_run(task, %{"instruction" => schedule.prompt}) do
      Logger.info("schedule_fired schedule=#{schedule.id} task=#{task.id}")
      :ok
    else
      {:error, reason} ->
        Logger.warning("schedule_launch_failed schedule=#{schedule.id}: #{inspect(reason)}")
        :ok
    end
  end
end
