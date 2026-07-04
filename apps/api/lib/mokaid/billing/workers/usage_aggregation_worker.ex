defmodule Mokaid.Billing.Workers.UsageAggregationWorker do
  @moduledoc """
  Nightly usage aggregation. Currently summarizes in PostgreSQL;
  will stream usage_events to ClickHouse when analytics volumes require it.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  import Ecto.Query

  alias Mokaid.Repo
  alias Mokaid.Workspaces.Workspace

  @impl Oban.Worker
  def perform(_job) do
    workspace_ids =
      Repo.all(from w in Workspace, where: is_nil(w.deleted_at), select: w.id)

    Enum.each(workspace_ids, fn workspace_id ->
      _summary = Mokaid.Billing.usage_summary(workspace_id)
      :ok
    end)

    :ok
  end
end
