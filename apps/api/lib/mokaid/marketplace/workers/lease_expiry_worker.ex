defmodule Mokaid.Marketplace.Workers.LeaseExpiryWorker do
  @moduledoc "Archives marketplace clones whose fixed-term lease has expired."

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias Mokaid.Marketplace

  @impl Oban.Worker
  def perform(_job) do
    Marketplace.expire_due_leases()
    :ok
  end
end
