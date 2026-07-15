defmodule Mokaid.Office.Workers.ActivitySchedulerWorker do
  @moduledoc "Periodically assigns / expires synchronized office social activities."

  use Oban.Worker, queue: :default, max_attempts: 2

  @impl Oban.Worker
  def perform(_job) do
    Mokaid.Office.tick_all_workspaces()
    :ok
  end
end
