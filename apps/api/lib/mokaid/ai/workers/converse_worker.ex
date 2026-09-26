defmodule Mokaid.AI.Workers.ConverseWorker do
  @moduledoc """
  Routes a persisted human message while an agent is idle. The Python worker
  classifies work versus conversation; Phoenix authorizes and applies its
  callback so an instruction starts an actual execution.
  """

  use Oban.Worker,
    queue: :ai_dispatch,
    max_attempts: 2,
    unique: [period: 60, fields: [:args], keys: [:workspace_id, :task_id, :comment_id]]

  alias Mokaid.AI
  alias Mokaid.Tasks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workspace_id" => workspace_id, "task_id" => task_id} = args}) do
    config = Application.fetch_env!(:mokaid, :ai_worker)
    task = Tasks.get_task(workspace_id, task_id)
    trigger = Mokaid.AI.TaskFollowup.trigger(workspace_id, task_id, args["comment_id"])

    cond do
      task == nil or task.assigned_agent_id == nil or trigger == nil ->
        :ok

      not Mokaid.AI.TaskFollowup.available_agent?(
        Mokaid.Agents.get_agent(workspace_id, task.assigned_agent_id)
      ) ->
        :ok

      # A live run already talks in the thread (ack, failure explanations);
      # don't have two voices at once.
      Tasks.active_runs_for_task(workspace_id, task_id) != [] and
          is_nil(Mokaid.AI.TaskFollowup.waiting_managed_run(workspace_id, task_id)) ->
        :ok

      true ->
        payload = %{
          workspace_id: workspace_id,
          task_id: task_id,
          agent_id: task.assigned_agent_id,
          task_title: task.title,
          task_description: task.description,
          task_status: task.status,
          trigger: %{id: trigger.id, body: trigger.body},
          conversation: AI.default_input(task)["conversation"]
        }

        Mokaid.AI.WorkerClient.post(
          "/converse",
          Map.put(payload, :type, "converse"),
          config: config
        )
    end
  end
end
