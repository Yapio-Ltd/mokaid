defmodule Mokaid.Billing.Workers.ProviderCostSyncWorker do
  @moduledoc "Nightly sync of OpenAI + Anthropic billed costs (J-1 + 3 day catch-up)."

  use Oban.Worker, queue: :billing, max_attempts: 3

  require Logger

  alias Mokaid.Billing.ProviderCostSync

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    days = Map.get(args, "days") || Map.get(args, :days) || 3
    yesterday = Date.utc_today() |> Date.add(-1)

    Enum.each(0..(max(days, 1) - 1), fn i ->
      day = Date.add(yesterday, -i)

      Enum.each(ProviderCostSync.sync_day(day), fn
        {:ok, meta} -> Logger.info("provider cost sync ok: #{inspect(meta)}")
        {:skip, reason} -> Logger.info("provider cost sync skip: #{inspect(reason)}")
        {:error, reason} -> Logger.warning("provider cost sync error: #{inspect(reason)}")
      end)
    end)

    :ok
  end
end
