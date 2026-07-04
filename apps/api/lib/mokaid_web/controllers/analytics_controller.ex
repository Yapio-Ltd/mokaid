defmodule MokaidWeb.AnalyticsController do
  use MokaidWeb, :controller

  alias Mokaid.Analytics

  def overview(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "analytics.view") do
      json(conn, %{
        data: %{
          overview: Analytics.overview(workspace_id(conn)),
          tasks_by_status: Analytics.tasks_by_status(workspace_id(conn)),
          tasks_by_priority: Analytics.tasks_by_priority(workspace_id(conn)),
          tasks_completed_daily: Analytics.tasks_completed_daily(workspace_id(conn)),
          top_agents: Analytics.top_agents(workspace_id(conn)),
          agent_task_split: Analytics.agent_task_split(workspace_id(conn))
        }
      })
    end
  end

  def agents(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "analytics.view") do
      json(conn, %{data: Analytics.top_agents(workspace_id(conn), 20)})
    end
  end

  def tasks(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "analytics.view") do
      json(conn, %{
        data: %{
          by_status: Analytics.tasks_by_status(workspace_id(conn)),
          by_priority: Analytics.tasks_by_priority(workspace_id(conn)),
          completed_daily: Analytics.tasks_completed_daily(workspace_id(conn), 30)
        }
      })
    end
  end
end
