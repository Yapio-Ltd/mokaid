defmodule MokaidWeb.Plugs.ClientAccess do
  @moduledoc "Apply authenticated client restrictions after route matching and authentication."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  alias Mokaid.Auth.ClientPolicy
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    # Controller-private fields are installed only after router pipelines run.
    # Ask the same compiled router/method/path matcher, never a path prefix or a
    # client-provided action header. Unknown/future routes remain default-deny.
    route = Phoenix.Router.route_info(MokaidWeb.Router, conn.method, conn.path_info, conn.host)

    {controller, action} =
      case route do
        %{plug: controller, plug_opts: action} -> {controller, action}
        _ -> {nil, nil}
      end

    if ClientPolicy.http_allowed?(
         Map.get(conn.assigns, :auth_session, %{}),
         controller,
         action
       ) do
      conn
    else
      # Log only the reviewed route category, never bearer material, query/body
      # contents or resource identifiers supplied by the request.
      Logger.info("Desktop-only business access denied for browser session",
        controller: controller,
        action: action
      )

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_status(:forbidden)
      |> json(%{
        error: %{
          code: "desktop_required",
          message:
            "Open Mokaid Desktop to access this feature. Account and billing remain available on the website.",
          download_url: "https://mokaid.com/download"
        }
      })
      |> halt()
    end
  end
end
