defmodule Mokaid.Billing.ProviderCostSync do
  @moduledoc """
  Syncs billed provider costs into `platform_cost_snapshots` and reconciles with
  internal `usage_events` estimates.

  Sources:
  - OpenAI Admin API: GET /v1/organization/costs
  - Anthropic Admin API: GET /v1/organizations/cost_report

  Keys must be Admin keys (`sk-admin-…`, `sk-ant-admin-…`), never inference keys.
  """

  require Logger
  import Ecto.Query

  alias Mokaid.Billing.{
    CostReconciliationDaily,
    PlatformCostSnapshot,
    UsageEvent
  }

  alias Mokaid.Repo

  @openai_base "https://api.openai.com/v1"
  @anthropic_base "https://api.anthropic.com/v1"

  @doc "Sync provider costs for a specific UTC day (Date)."
  def sync_day(%Date{} = day) do
    results = [
      sync_openai_day(day),
      sync_anthropic_day(day)
    ]

    Enum.each(~w(openai anthropic), fn provider ->
      reconcile_day(day, provider)
    end)

    results
  end

  @doc "Backfill last N days (default 30) ending yesterday UTC."
  def backfill(days \\ 30) when is_integer(days) and days > 0 do
    yesterday = Date.utc_today() |> Date.add(-1)

    Enum.map(0..(days - 1), fn i ->
      day = Date.add(yesterday, -i)
      {day, sync_day(day)}
    end)
  end

  # ---------- OpenAI ----------

  def sync_openai_day(%Date{} = day) do
    case openai_key() do
      nil ->
        {:skip, :missing_key}

      key ->
        start_unix = day_start_unix(day)
        end_unix = day_start_unix(Date.add(day, 1))

        with {:ok, buckets} <-
               fetch_openai_costs(key, start_unix, end_unix) do
          fetched_at = DateTime.utc_now()
          total_cents = upsert_openai_buckets(day, buckets, fetched_at)
          {:ok, %{provider: "openai", day: day, amount_cents: total_cents}}
        end
    end
  end

  defp fetch_openai_costs(key, start_unix, end_unix, page \\ nil, acc \\ []) do
    params =
      [
        start_time: start_unix,
        end_time: end_unix,
        bucket_width: "1d",
        group_by: "line_item",
        limit: 30
      ]
      |> then(fn p -> if page, do: Keyword.put(p, :page, page), else: p end)

    url = "#{@openai_base}/organization/costs"

    case Req.get(url,
           headers: [
             {"authorization", "Bearer #{key}"},
             {"content-type", "application/json"}
           ],
           params: params,
           receive_timeout: 30_000,
           retry: :transient,
           max_retries: 3
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        data = Map.get(body, "data") || []
        acc = acc ++ data
        next = Map.get(body, "next_page")

        if is_binary(next) and next != "" do
          fetch_openai_costs(key, start_unix, end_unix, next, acc)
        else
          {:ok, acc}
        end

      {:ok, %{status: 401}} ->
        Logger.error("OpenAI cost sync unauthorized — check OPENAI_ADMIN_API_KEY")
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenAI cost sync failed status=#{status}")
        {:error, {:http_error, status, sanitize_body(body)}}

      {:error, reason} ->
        Logger.error("OpenAI cost sync transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp upsert_openai_buckets(day, buckets, fetched_at) do
    period_start = day_start_dt(day)
    period_end = day_start_dt(Date.add(day, 1))

    rows =
      buckets
      |> Enum.flat_map(fn bucket ->
        results = Map.get(bucket, "results") || []

        Enum.map(results, fn result ->
          amount = get_in(result, ["amount", "value"]) || 0
          cents = usd_to_cents(amount)
          line_item = Map.get(result, "line_item") || "unknown"
          project_id = Map.get(result, "project_id")

          breakdown = %{
            "line_item" => line_item,
            "project_id" => project_id
          }

          %{
            provider: "openai",
            granularity: "day",
            period_start: period_start,
            period_end: period_end,
            amount_cents: cents,
            currency: "USD",
            breakdown: breakdown,
            breakdown_key: breakdown_key(breakdown),
            source: "admin_api",
            fetched_at: fetched_at,
            raw_payload: strip_large(result)
          }
        end)
      end)

    if rows == [] do
      upsert_snapshot(%{
        provider: "openai",
        granularity: "day",
        period_start: period_start,
        period_end: period_end,
        amount_cents: 0,
        currency: "USD",
        breakdown: %{"total" => true},
        breakdown_key: "total",
        source: "admin_api",
        fetched_at: fetched_at,
        raw_payload: %{}
      })

      0
    else
      Enum.reduce(rows, 0, fn row, acc ->
        upsert_snapshot(row)
        acc + row.amount_cents
      end)
    end
  end

  # ---------- Anthropic ----------

  def sync_anthropic_day(%Date{} = day) do
    case anthropic_key() do
      nil ->
        {:skip, :missing_key}

      key ->
        starting_at = DateTime.to_iso8601(day_start_dt(day))
        ending_at = DateTime.to_iso8601(day_start_dt(Date.add(day, 1)))

        with {:ok, data} <- fetch_anthropic_costs(key, starting_at, ending_at) do
          fetched_at = DateTime.utc_now()
          total = upsert_anthropic_data(day, data, fetched_at)
          {:ok, %{provider: "anthropic", day: day, amount_cents: total}}
        end
    end
  end

  defp fetch_anthropic_costs(key, starting_at, ending_at, page \\ nil, acc \\ []) do
    params =
      [
        starting_at: starting_at,
        ending_at: ending_at,
        bucket_width: "1d",
        group_by: ["description"]
      ]
      |> then(fn p -> if page, do: Keyword.put(p, :page, page), else: p end)

    case Req.get("#{@anthropic_base}/organizations/cost_report",
           headers: [
             {"x-api-key", key},
             {"anthropic-version", "2023-06-01"},
             {"content-type", "application/json"}
           ],
           params: params,
           receive_timeout: 30_000,
           retry: :transient,
           max_retries: 3
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        data = Map.get(body, "data") || []
        acc = acc ++ data
        has_more = Map.get(body, "has_more") == true
        next = Map.get(body, "next_page")

        if has_more and is_binary(next) and next != "" do
          fetch_anthropic_costs(key, starting_at, ending_at, next, acc)
        else
          {:ok, acc}
        end

      {:ok, %{status: 401}} ->
        Logger.error("Anthropic cost sync unauthorized — check ANTHROPIC_ADMIN_API_KEY")
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Anthropic cost sync failed status=#{status}")
        {:error, {:http_error, status, sanitize_body(body)}}

      {:error, reason} ->
        Logger.error("Anthropic cost sync transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp upsert_anthropic_data(day, data, fetched_at) do
    period_start = day_start_dt(day)
    period_end = day_start_dt(Date.add(day, 1))

    # Anthropic returns amount as decimal string in cents ("123.45" = $1.2345)
    # Docs: amount is in cents with string form; many samples use USD minor units.
    rows =
      Enum.flat_map(data, fn bucket ->
        results = Map.get(bucket, "results") || [bucket]

        Enum.map(List.wrap(results), fn result ->
          amount_str = Map.get(result, "amount") || "0"
          cents = anthropic_amount_to_cents(amount_str)
          model = Map.get(result, "model")
          description = Map.get(result, "description") || Map.get(result, "cost_type") || "tokens"

          breakdown = %{
            "model" => model,
            "description" => description,
            "service_tier" => Map.get(result, "service_tier"),
            "token_type" => Map.get(result, "token_type")
          }

          %{
            provider: "anthropic",
            granularity: "day",
            period_start: period_start,
            period_end: period_end,
            amount_cents: cents,
            currency: Map.get(result, "currency") || "USD",
            breakdown: breakdown,
            breakdown_key: breakdown_key(breakdown),
            source: "admin_api",
            fetched_at: fetched_at,
            raw_payload: strip_large(result)
          }
        end)
      end)

    if rows == [] do
      upsert_snapshot(%{
        provider: "anthropic",
        granularity: "day",
        period_start: period_start,
        period_end: period_end,
        amount_cents: 0,
        currency: "USD",
        breakdown: %{"total" => true},
        breakdown_key: "total",
        source: "admin_api",
        fetched_at: fetched_at,
        raw_payload: %{}
      })

      0
    else
      Enum.reduce(rows, 0, fn row, acc ->
        upsert_snapshot(row)
        acc + row.amount_cents
      end)
    end
  end

  # ---------- Reconciliation ----------

  def reconcile_day(%Date{} = day, provider) when provider in ~w(openai anthropic) do
    period_start = day_start_dt(day)
    period_end = day_start_dt(Date.add(day, 1))

    provider_cents =
      Repo.one(
        from s in PlatformCostSnapshot,
          where:
            s.provider == ^provider and s.period_start == ^period_start and
              s.granularity == "day",
          select: coalesce(sum(s.amount_cents), 0)
      ) || 0

    # Internal estimates from usage_events in the same window (all workspaces)
    internal_cents =
      Repo.one(
        from e in UsageEvent,
          where: e.occurred_at >= ^period_start and e.occurred_at < ^period_end,
          select: coalesce(sum(e.cost_cents), 0)
      ) || 0

    # Split internal roughly by provider if metadata has model prefixes; else attribute all as total under both with note
    internal_for_provider =
      case provider do
        "openai" ->
          Repo.one(
            from e in UsageEvent,
              where:
                e.occurred_at >= ^period_start and e.occurred_at < ^period_end and
                  (fragment("(?->>'provider') = ?", e.metadata, "openai") or
                     fragment("coalesce(?->>'model','') ILIKE 'gpt%'", e.metadata) or
                     fragment("coalesce(?->>'model','') ILIKE 'o1%'", e.metadata) or
                     fragment("coalesce(?->>'model','') ILIKE 'text-embedding%'", e.metadata)),
              select: coalesce(sum(e.cost_cents), 0)
          ) || 0

        "anthropic" ->
          Repo.one(
            from e in UsageEvent,
              where:
                e.occurred_at >= ^period_start and e.occurred_at < ^period_end and
                  (fragment("(?->>'provider') = ?", e.metadata, "anthropic") or
                     fragment("coalesce(?->>'model','') ILIKE 'claude%'", e.metadata)),
              select: coalesce(sum(e.cost_cents), 0)
          ) || 0
      end

    # Fall back to total internal if no provider tags (avoid double-zero)
    internal_for_provider =
      if internal_for_provider == 0 and provider == "openai",
        do: internal_cents,
        else: internal_for_provider

    delta = provider_cents - internal_for_provider

    attrs = %{
      day: day,
      provider: provider,
      provider_reported_cents: provider_cents,
      internal_usage_cents: internal_for_provider,
      delta_cents: delta,
      notes:
        if(abs(delta) > 500,
          do: "delta over $5 — review pricing table or missing usage events",
          else: nil
        )
    }

    case Repo.get_by(CostReconciliationDaily, day: day, provider: provider) do
      nil ->
        %CostReconciliationDaily{}
        |> CostReconciliationDaily.changeset(attrs)
        |> Repo.insert()

      row ->
        row
        |> CostReconciliationDaily.changeset(attrs)
        |> Repo.update()
    end
  end

  # ---------- helpers ----------

  defp upsert_snapshot(attrs) do
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

  defp openai_key do
    key = Application.get_env(:mokaid, :provider_costs, [])[:openai_admin_api_key]
    if is_binary(key) and key != "" and key != "CHANGE_ME", do: key, else: nil
  end

  defp anthropic_key do
    key = Application.get_env(:mokaid, :provider_costs, [])[:anthropic_admin_api_key]
    if is_binary(key) and key != "" and key != "CHANGE_ME", do: key, else: nil
  end

  defp day_start_dt(%Date{} = day) do
    {:ok, dt} = DateTime.new(day, ~T[00:00:00], "Etc/UTC")
    DateTime.truncate(dt, :microsecond)
  end

  defp day_start_unix(%Date{} = day), do: DateTime.to_unix(day_start_dt(day))

  defp usd_to_cents(v) when is_number(v), do: round(v * 100)
  defp usd_to_cents(%Decimal{} = d), do: d |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()

  defp usd_to_cents(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> round(f * 100)
      :error -> 0
    end
  end

  defp usd_to_cents(_), do: 0

  # Anthropic docs: amount string in cents of USD ("123.45" = $1.2345).
  defp anthropic_amount_to_cents(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> round(f)
      :error -> 0
    end
  end

  defp anthropic_amount_to_cents(v) when is_number(v), do: round(v)
  defp anthropic_amount_to_cents(_), do: 0

  defp breakdown_key(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join("|")
    |> case do
      "" -> "default"
      s -> :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    end
  end

  defp strip_large(map) when is_map(map) do
    map
    |> Map.drop(["raw", "prompt", "messages", "input", "output", "content"])
    |> Map.take(~w(amount line_item project_id model description cost_type service_tier token_type currency quantity))
  end

  defp sanitize_body(body) when is_map(body), do: Map.take(body, ["error", "type", "message"])
  defp sanitize_body(_), do: %{}
end
