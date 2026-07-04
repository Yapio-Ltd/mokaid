defmodule Mokaid.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Mokaid.Repo,
      {Phoenix.PubSub, name: Mokaid.PubSub},
      MokaidWeb.Presence,
      {Oban, Application.fetch_env!(:mokaid, Oban)},
      {Task.Supervisor, name: Mokaid.TaskSupervisor},
      MokaidWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Mokaid.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MokaidWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
