defmodule MokaidWeb.Plugs.WorkerAuth do
  @moduledoc "Authenticates the internal AI worker via a shared bearer token."

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.fetch_env!(:mokaid, :ai_worker)[:token]

    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token == expected ->
        conn

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "Invalid worker token"}})
        |> halt()
    end
  end
end
