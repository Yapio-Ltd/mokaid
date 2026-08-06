defmodule Mokaid.Observability.CloudWatchLogs do
  @moduledoc """
  Read-only proxy to CloudWatch Logs for the operator CRM global logs view.
  Strict time window, pagination limits, and message redaction.
  """

  require Logger

  @max_events 100
  @default_hours 6

  def filter(opts \\ %{}) do
    groups = log_groups()

    if groups == [] do
      []
    else
      hours = clamp_int(Map.get(opts, "hours"), @default_hours, 1, 72)
      end_ms = System.system_time(:millisecond)
      start_ms = end_ms - hours * 3_600_000
      filter_pattern = Map.get(opts, "q") || Map.get(opts, "filter") || ""
      region = Application.get_env(:mokaid, :provider_costs, [])[:aws_region] || "il-central-1"

      groups
      |> Enum.flat_map(fn group ->
        fetch_group(group, start_ms, end_ms, filter_pattern, region)
      end)
      |> Enum.sort_by(& &1.occurred_at, {:desc, DateTime})
      |> Enum.take(@max_events)
    end
  rescue
    e ->
      Logger.warning("CloudWatch filter failed: #{inspect(e)}")
      []
  end

  defp fetch_group(group, start_ms, end_ms, filter_pattern, region) do
    data = %{
      "logGroupName" => group,
      "startTime" => start_ms,
      "endTime" => end_ms,
      "limit" => 50,
      "interleaved" => true
    }

    data =
      if is_binary(filter_pattern) and String.trim(filter_pattern) != "" do
        Map.put(data, "filterPattern", String.slice(filter_pattern, 0, 120))
      else
        data
      end

    op = %ExAws.Operation.JSON{
      http_method: :post,
      headers: [
        {"x-amz-target", "Logs_20140328.FilterLogEvents"},
        {"content-type", "application/x-amz-json-1.1"}
      ],
      data: data,
      service: :logs
    }

    case ExAws.request(op, region: region) do
      {:ok, response} ->
        events = Map.get(response, "events") || Map.get(response, :events) || []

        Enum.map(events, fn event ->
          ts = Map.get(event, "timestamp") || Map.get(event, :timestamp) || start_ms
          msg = Map.get(event, "message") || Map.get(event, :message) || ""
          stream = Map.get(event, "logStreamName") || Map.get(event, :logStreamName)

          occurred =
            case DateTime.from_unix(div(ts, 1000)) do
              {:ok, dt} -> dt
              _ -> DateTime.utc_now()
            end

          %{
            id: "cw-#{group}-#{ts}-#{:erlang.phash2(msg)}",
            source: "cloudwatch",
            occurred_at: occurred,
            actor: "system",
            action: "log.event",
            resource_type: "log_group",
            resource_id: nil,
            workspace_id: nil,
            message: redact_message(msg),
            metadata: %{
              "log_group" => group,
              "log_stream" => stream
            }
          }
        end)

      {:error, reason} ->
        Logger.info("CloudWatch logs skip group=#{group}: #{inspect(reason)}")
        []
    end
  end

  defp redact_message(msg) when is_binary(msg) do
    msg
    |> String.replace(
      ~r/(?i)(authorization|api[_-]?key|token|password|secret)\s*[:=]\s*\S+/,
      "\\1=[REDACTED]"
    )
    |> String.replace(~r/sk-(?:ant-)?[a-zA-Z0-9_\-]{10,}/, "[REDACTED_KEY]")
    |> String.replace(~r/Bearer\s+[A-Za-z0-9\-._~+\/]+=*/, "Bearer [REDACTED]")
    |> String.slice(0, 2000)
  end

  defp redact_message(_), do: ""

  defp log_groups do
    Application.get_env(:mokaid, :provider_costs, [])[:log_groups] || []
  end

  defp clamp_int(nil, default, _min, _max), do: default
  defp clamp_int(v, _d, min, max) when is_integer(v), do: v |> max(min) |> min(max)

  defp clamp_int(v, default, min, max) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> clamp_int(n, default, min, max)
      _ -> default
    end
  end

  defp clamp_int(_, default, _, _), do: default
end
