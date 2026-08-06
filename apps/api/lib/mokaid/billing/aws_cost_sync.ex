defmodule Mokaid.Billing.AwsCostSync do
  @moduledoc """
  Syncs AWS Cost Explorer DAILY costs for the Mokaid project into
  `platform_cost_snapshots` (provider = "aws").

  Cost Explorer is a global endpoint (us-east-1). Task role needs
  ce:GetCostAndUsage.
  """

  require Logger

  alias Mokaid.Billing.PlatformCostSnapshot
  alias Mokaid.Repo

  @doc "Sync cost for a single UTC day."
  def sync_day(%Date{} = day) do
    start = Date.to_iso8601(day)
    # CE end is exclusive
    ending = Date.to_iso8601(Date.add(day, 1))
    region = ce_region()

    body = %{
      "TimePeriod" => %{"Start" => start, "End" => ending},
      "Granularity" => "DAILY",
      "Metrics" => ["UnblendedCost"],
      "GroupBy" => [%{"Type" => "DIMENSION", "Key" => "SERVICE"}]
    }

    # Prefer project tag filter when available
    body =
      case project_tag() do
        tag when is_binary(tag) and tag != "" ->
          Map.put(body, "Filter", %{
            "Tags" => %{"Key" => "Project", "Values" => [tag]}
          })

        _ ->
          body
      end

    op = %ExAws.Operation.JSON{
      http_method: :post,
      headers: [
        {"x-amz-target", "AWSInsightsIndexService.GetCostAndUsage"},
        {"content-type", "application/x-amz-json-1.1"}
      ],
      data: body,
      service: :ce
    }

    case ExAws.request(op, region: region) do
      {:ok, response} ->
        fetched_at = DateTime.utc_now()
        total = upsert_from_response(day, response, fetched_at)
        {:ok, %{provider: "aws", day: day, amount_cents: total}}

      {:error, reason} ->
        Logger.error("AWS Cost Explorer sync failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def backfill(days \\ 30) when is_integer(days) and days > 0 do
    yesterday = Date.utc_today() |> Date.add(-1)

    Enum.map(0..(days - 1), fn i ->
      day = Date.add(yesterday, -i)
      {day, sync_day(day)}
    end)
  end

  defp upsert_from_response(day, response, fetched_at) do
    period_start = day_start_dt(day)
    period_end = day_start_dt(Date.add(day, 1))

    results_by_time =
      Map.get(response, "ResultsByTime") || Map.get(response, :ResultsByTime) || []

    rows =
      Enum.flat_map(results_by_time, fn block ->
        groups = Map.get(block, "Groups") || Map.get(block, :Groups) || []

        Enum.map(groups, fn group ->
          keys = Map.get(group, "Keys") || Map.get(group, :Keys) || ["Unknown"]
          service = List.first(keys) || "Unknown"
          metrics = Map.get(group, "Metrics") || Map.get(group, :Metrics) || %{}

          amount_str =
            get_in(metrics, ["UnblendedCost", "Amount"]) ||
              get_in(metrics, [:UnblendedCost, :Amount]) ||
              "0"

          cents = usd_string_to_cents(amount_str)
          breakdown = %{"service" => service}

          %{
            provider: "aws",
            granularity: "day",
            period_start: period_start,
            period_end: period_end,
            amount_cents: cents,
            currency: "USD",
            breakdown: breakdown,
            breakdown_key: service_key(service),
            source: "cost_explorer",
            fetched_at: fetched_at,
            raw_payload: %{"service" => service, "amount" => amount_str}
          }
        end)
      end)

    if rows == [] do
      upsert(%{
        provider: "aws",
        granularity: "day",
        period_start: period_start,
        period_end: period_end,
        amount_cents: 0,
        currency: "USD",
        breakdown: %{"total" => true},
        breakdown_key: "total",
        source: "cost_explorer",
        fetched_at: fetched_at,
        raw_payload: %{}
      })

      0
    else
      Enum.reduce(rows, 0, fn row, acc ->
        upsert(row)
        acc + row.amount_cents
      end)
    end
  end

  defp upsert(attrs) do
    case Repo.get_by(PlatformCostSnapshot,
           provider: attrs.provider,
           period_start: attrs.period_start,
           granularity: attrs.granularity,
           breakdown_key: attrs.breakdown_key
         ) do
      nil ->
        %PlatformCostSnapshot{}
        |> PlatformCostSnapshot.changeset(attrs)
        |> Repo.insert()

      row ->
        row
        |> PlatformCostSnapshot.changeset(attrs)
        |> Repo.update()
    end
  end

  defp day_start_dt(%Date{} = day) do
    {:ok, dt} = DateTime.new(day, ~T[00:00:00], "Etc/UTC")
    DateTime.truncate(dt, :microsecond)
  end

  defp usd_string_to_cents(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> round(f * 100)
      :error -> 0
    end
  end

  defp usd_string_to_cents(_), do: 0

  defp service_key(service) do
    service
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.slice(0, 64)
  end

  defp ce_region do
    Application.get_env(:mokaid, :provider_costs, [])[:cost_explorer_region] || "us-east-1"
  end

  defp project_tag do
    Application.get_env(:mokaid, :provider_costs, [])[:project_tag] || "mokaid"
  end
end
