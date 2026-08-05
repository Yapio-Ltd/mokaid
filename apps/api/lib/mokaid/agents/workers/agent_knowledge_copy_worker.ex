defmodule Mokaid.Agents.Workers.AgentKnowledgeCopyWorker do
  @moduledoc """
  Background copy of a transferred agent's knowledge corpus into the target
  workspace. Idempotent (already-copied items are skipped), so retries after
  a partial failure only copy what is missing.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  alias Mokaid.Agents.Transfer

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "source_workspace_id" => source_workspace_id,
          "source_agent_id" => source_agent_id,
          "target_workspace_id" => target_workspace_id,
          "target_agent_id" => target_agent_id
        }
      }) do
    Transfer.copy_knowledge(
      source_workspace_id,
      source_agent_id,
      target_workspace_id,
      target_agent_id
    )
  end
end
