defmodule MokaidWeb.CalendarController do
  use MokaidWeb, :controller

  alias Mokaid.Calendar
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "calendar.view") do
      events = Calendar.list_events(workspace_id(conn), params)
      json(conn, %{data: Enum.map(events, &Serializer.calendar_event/1)})
    end
  end

  def create(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "calendar.create"),
         {:ok, event} <- Calendar.create_event(workspace_id(conn), params) do
      conn
      |> put_status(:created)
      |> json(%{data: %{id: event.id, title: event.title}})
    end
  end
end
