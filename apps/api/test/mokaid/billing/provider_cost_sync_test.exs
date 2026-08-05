defmodule Mokaid.Billing.ProviderCostSyncTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Billing.ProviderCostSync
  alias Mokaid.Billing.PlatformCostSnapshot
  alias Mokaid.Repo

  test "usd conversion helpers via public sync skip without keys" do
    day = ~D[2026-08-01]
    assert {:skip, :missing_key} = ProviderCostSync.sync_openai_day(day)
    assert {:skip, :missing_key} = ProviderCostSync.sync_anthropic_day(day)
  end

  test "upsert snapshot is idempotent for same key" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    day = Date.utc_today()
    {:ok, period_start} = DateTime.new(day, ~T[00:00:00], "Etc/UTC")
    period_start = DateTime.truncate(period_start, :microsecond)
    period_end = DateTime.add(period_start, 86400, :second)

    attrs = %{
      provider: "openai",
      granularity: "day",
      period_start: period_start,
      period_end: period_end,
      amount_cents: 123,
      currency: "USD",
      breakdown: %{"line_item" => "test"},
      breakdown_key: "test-key",
      source: "admin_api",
      fetched_at: now,
      raw_payload: %{}
    }

    assert {:ok, _} =
             %PlatformCostSnapshot{}
             |> PlatformCostSnapshot.changeset(attrs)
             |> Repo.insert()

    assert {:ok, updated} =
             Repo.get_by!(PlatformCostSnapshot,
               provider: "openai",
               period_start: period_start,
               granularity: "day",
               breakdown_key: "test-key"
             )
             |> PlatformCostSnapshot.changeset(%{amount_cents: 456, fetched_at: now})
             |> Repo.update()

    assert updated.amount_cents == 456
    assert Repo.aggregate(PlatformCostSnapshot, :count) == 1
  end
end
