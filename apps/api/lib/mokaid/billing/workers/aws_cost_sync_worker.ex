defmodule Mokaid.Billing.Workers.AwsCostSyncWorker do
  @moduledoc "Nightly AWS Cost Explorer sync (J-1 + 3 day catch-up)."

  use Oban.Worker, queue: :billing, max_attempts: 3

  require Logger

  alias Mokaid.Billing.AwsCostSync

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days = Map.get(args, "days") || Map.get(args, :days) || 3
    yesterday = Date.utc_today() |> Date.add(-1)

    Enum.each(0..(max(days, 1) - 1), fn i ->
      day = Date.add(yesterday, -i)

      case AwsCostSync.sync_day(day) do
        {:ok, meta} -> Logger.info("aws cost sync ok: #{inspect(meta)}")
        {:error, reason} -> Logger.warning("aws cost sync error: #{inspect(reason)}")
      end
    end)

    :ok
  end
end
