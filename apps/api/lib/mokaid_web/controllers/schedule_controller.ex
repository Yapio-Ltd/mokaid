defmodule MokaidWeb.ScheduleController do
  use MokaidWeb, :controller

  alias Mokaid.Agents
  alias Mokaid.AI.Schedules
  alias MokaidWeb.JSON, as: Serializer

  @schedule_params ~w(name cron_expression timezone prompt enabled max_runs expires_at)

  def index(conn, %{"agent_id" => agent_id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), agent_id) do
      schedules = Schedules.list_schedules(workspace_id(conn), agent.id)
      json(conn, %{data: Enum.map(schedules, &Serializer.schedule/1)})
    end
  end

  def create(conn, %{"agent_id" => agent_id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.update"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), agent_id),
         {:ok, schedule} <-
           Schedules.create_schedule(
             workspace_id(conn),
             agent.id,
             Map.take(params, @schedule_params),
             current_member(conn)
           ) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.schedule(schedule)})
    end
  end

  def update(conn, %{"agent_id" => agent_id, "id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.update"),
         %{} = schedule <- Schedules.get_schedule(workspace_id(conn), id),
         true <- schedule.agent_id == agent_id || {:error, :not_found},
         {:ok, updated} <-
           Schedules.update_schedule(schedule, Map.take(params, @schedule_params)) do
      json(conn, %{data: Serializer.schedule(updated)})
    end
  end

  def delete(conn, %{"agent_id" => agent_id, "id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.update"),
         %{} = schedule <- Schedules.get_schedule(workspace_id(conn), id),
         true <- schedule.agent_id == agent_id || {:error, :not_found},
         {:ok, _} <- Schedules.delete_schedule(schedule) do
      json(conn, %{ok: true})
    end
  end

  @doc """
  Natural-language automation parsing, proxied to the AI worker:
  "chaque lundi 9h, prépare le rapport hebdo" → {name, cron, prompt}.
  503 when no LLM is configured — the UI falls back to manual entry.
  """
  def parse(conn, %{"agent_id" => agent_id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.update"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), agent_id) do
      case worker_parse(params["text"] || "", agent) do
        {:ok, result} ->
          json(conn, %{data: result})

        {:error, status} when is_integer(status) ->
          conn
          |> put_status(status)
          |> json(%{error: %{code: "parse_failed", message: "Could not parse the schedule"}})

        {:error, _} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: %{code: "worker_unavailable", message: "AI worker unreachable"}})
      end
    end
  end

  defp worker_parse(text, agent) do
    config = Application.fetch_env!(:mokaid, :ai_worker)

    if config[:dispatch] == :http and Mokaid.AI.WorkerClient.absolute_url?(config[:url]) do
      url = String.trim_trailing(config[:url], "/") <> "/schedules/parse"

      payload = %{
        text: text,
        agent: %{display_name: agent.display_name, role_title: agent.role_title}
      }

      case Req.post(
             url: url,
             json: payload,
             headers: [{"authorization", "Bearer #{config[:token]}"}],
             receive_timeout: 30_000,
             retry: false
           ) do
        {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
        {:ok, %{status: status}} -> {:error, status}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :worker_not_configured}
    end
  end
end
