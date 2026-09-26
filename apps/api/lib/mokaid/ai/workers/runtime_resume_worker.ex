defmodule Mokaid.AI.Workers.RuntimeResumeWorker do
  @moduledoc "Durable delivery of an authorized continuation; never creates another run."
  use Oban.Worker,
    queue: :ai_dispatch,
    max_attempts: 15,
    unique: [period: :infinity, fields: [:worker, :args], keys: [:workspace_id, :request_id]]

  alias Mokaid.{Repo, Tasks}
  alias Mokaid.AI.RuntimeRun

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "run_id" => run_id,
            "workspace_id" => workspace_id,
            "request_id" => request_id,
            "budget_revision" => revision
          } = args
      }) do
    with %{workspace_id: ^workspace_id, status: status} <- Tasks.get_run(run_id),
         true <- status not in ~w(completed failed canceled),
         %{status: "reserved", budget_revision: ^revision} <-
           Repo.get_by(RuntimeRun, run_id: run_id) do
      Mokaid.AI.WorkerClient.post("/runs/#{run_id}/resume", %{
        run_id: run_id,
        type: "resume",
        decision: "approved",
        tool_name: nil,
        command_id: request_id,
        payload: args["payload"] || %{runtime_budget_extended: true, budget_revision: revision}
      })
    else
      _ -> :ok
    end
  end
end
