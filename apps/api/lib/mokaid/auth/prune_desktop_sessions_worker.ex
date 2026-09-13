defmodule Mokaid.Auth.PruneDesktopSessionsWorker do
  @moduledoc "Bounds retention of expired desktop sessions and pending authorizations."
  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 3600]

  @impl Oban.Worker
  def perform(_job), do: Mokaid.Auth.Desktop.prune_expired()
end
