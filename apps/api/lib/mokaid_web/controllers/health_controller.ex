defmodule MokaidWeb.HealthController do
  use MokaidWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok", service: "mokaid-api", version: "0.1.0"})
  end
end
