defmodule Mokaid.AI do
  @moduledoc """
  AI run orchestration: dispatches task execution to the Python worker
  (SQS in production, direct HTTP in dev) and processes worker callbacks.
  """

  alias Mokaid.Agents
  alias Mokaid.Billing
  alias Mokaid.Realtime
  alias Mokaid.Tasks
  alias Mokaid.Tasks.Task, as: WorkTask

  @doc "Creates an execution run for a task and dispatches it to the AI worker."
  def start_run(%WorkTask{} = task, input \\ %{}) do
    with :ok <- validate_ai_assignable(task),
         {:ok, run} <- Tasks.create_execution_run(task, input) do
      case Agents.get_agent(task.workspace_id, task.assigned_agent_id) do
        nil -> :ok
        agent -> Agents.change_status(agent, "busy", current_task_id: task.id, reason: "ai_run")
      end

      Billing.record_usage(task.workspace_id, "agent", task.assigned_agent_id, "ai_request", 1, "request")

      %{run_id: run.id, workspace_id: task.workspace_id}
      |> Mokaid.AI.Workers.DispatchWorker.new()
      |> Oban.insert()

      {:ok, run}
    end
  end

  defp validate_ai_assignable(%WorkTask{assigned_agent_id: nil}), do: {:error, :no_agent_assigned}
  defp validate_ai_assignable(_task), do: :ok

  @doc "Handles a progress callback from the AI worker."
  def handle_progress(run_id, attrs) do
    with %{} = run <- Tasks.get_run(run_id) do
      Tasks.update_run_progress(run, attrs)
    else
      nil -> {:error, :run_not_found}
    end
  end

  def handle_approval_request(run_id, attrs) do
    with %{} = run <- Tasks.get_run(run_id),
         {:ok, run} <- Tasks.update_run_progress(run, %{"status" => "waiting_for_approval"}),
         {:ok, request} <- Tasks.create_approval_request(run, attrs) do
      case Agents.get_agent(run.workspace_id, run.agent_id) do
        nil -> :ok
        agent -> Agents.change_status(agent, "waiting", reason: "approval_requested")
      end

      {:ok, request}
    else
      nil -> {:error, :run_not_found}
      error -> error
    end
  end

  def handle_completion(run_id, output, token_usage \\ %{}, cost_cents \\ 0) do
    with %{} = run <- Tasks.get_run(run_id),
         {:ok, run} <-
           Tasks.update_run_progress(run, %{
             "status" => "completed",
             "output" => output,
             "token_usage" => token_usage,
             "cost_cents" => cost_cents
           }) do
      if cost_cents > 0 do
        Billing.record_usage(run.workspace_id, "agent", run.agent_id, "ai_cost", 1, "run",
          cost_cents: cost_cents
        )
      end

      case Tasks.get_task(run.workspace_id, run.task_id) do
        nil -> :ok
        task -> Tasks.update_task(task, %{"status" => "in_review", "progress_percent" => 100})
      end

      Realtime.broadcast_workspace(run.workspace_id, "task.progress_changed", %{
        task_id: run.task_id,
        run_id: run.id,
        status: "completed"
      })

      {:ok, run}
    else
      nil -> {:error, :run_not_found}
      error -> error
    end
  end

  def handle_failure(run_id, error_message) do
    with %{} = run <- Tasks.get_run(run_id),
         {:ok, run} <-
           Tasks.update_run_progress(run, %{"status" => "failed", "error" => error_message}) do
      case Agents.get_agent(run.workspace_id, run.agent_id) do
        nil -> :ok
        agent -> Agents.change_status(agent, "blocked", reason: "run_failed")
      end

      {:ok, run}
    else
      nil -> {:error, :run_not_found}
      error -> error
    end
  end

  @doc "Resumes a paused run after a human decision on an approval request."
  def resume_after_approval(run_id, decision) do
    config = Application.fetch_env!(:mokaid, :ai_worker)

    body = %{run_id: run_id, decision: decision}

    Req.post(
      url: "#{config[:url]}/runs/#{run_id}/resume",
      json: body,
      headers: [{"authorization", "Bearer #{config[:token]}"}],
      retry: false
    )
  end
end
