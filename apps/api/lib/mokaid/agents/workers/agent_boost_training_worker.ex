defmodule Mokaid.Agents.Workers.AgentBoostTrainingWorker do
  @moduledoc """
  Progressive head-start training after a paid boost purchase.

  Climbs the agent from level 1 to the boost target, injects domain packs for
  L10, and broadcasts realtime progress so the training UI can celebrate.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Mokaid.Agents

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"workspace_id" => workspace_id, "agent_id" => agent_id} = args
      }) do
    opts = [member_id: args["member_id"]]

    case Agents.run_boost_training(workspace_id, agent_id, opts) do
      :ok -> :ok
      {:ok, _agent} -> :ok
      {:cancel, reason} -> {:cancel, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
