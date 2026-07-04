defmodule Mokaid.Calendar do
  @moduledoc "Calendar events: meetings, deadlines, milestones, leaves."

  import Ecto.Query

  alias Mokaid.Calendar.CalendarEvent
  alias Mokaid.Realtime
  alias Mokaid.Repo

  def list_events(workspace_id, filters \\ %{}) do
    from(e in CalendarEvent,
      where: e.workspace_id == ^workspace_id,
      preload: [:project, :task, :agent, member: :user],
      order_by: [asc: e.start_at]
    )
    |> maybe_range(filters["from"], filters["to"])
    |> maybe_filter(:agent_id, filters["agent_id"])
    |> maybe_filter(:project_id, filters["project_id"])
    |> Repo.all()
  end

  defp maybe_range(query, nil, _), do: query

  defp maybe_range(query, from_str, to_str) do
    with {:ok, from_dt, _} <- DateTime.from_iso8601(from_str),
         {:ok, to_dt, _} <- DateTime.from_iso8601(to_str || from_str) do
      where(query, [e], e.start_at >= ^from_dt and e.start_at <= ^to_dt)
    else
      _ -> query
    end
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [e], field(e, ^field) == ^value)

  def create_event(workspace_id, attrs) do
    result =
      %CalendarEvent{}
      |> CalendarEvent.changeset(Map.put(attrs, "workspace_id", workspace_id))
      |> Repo.insert()

    with {:ok, event} <- result do
      Realtime.broadcast_workspace(workspace_id, "calendar.event_created", %{event_id: event.id})
      {:ok, event}
    end
  end

  def create_leave_event(leave_request, member_name) do
    kind_title =
      case leave_request.type do
        "vacation" -> "Vacation"
        "sick_leave" -> "Sick leave"
        "remote_work" -> "Remote work"
        _ -> "Time off"
      end

    create_event(leave_request.workspace_id, %{
      "title" => "#{kind_title} — #{member_name}",
      "kind" => "leave",
      "start_at" => leave_request.start_at,
      "end_at" => leave_request.end_at,
      "all_day" => true,
      "member_id" => leave_request.member_id,
      "leave_request_id" => leave_request.id
    })
  end
end
