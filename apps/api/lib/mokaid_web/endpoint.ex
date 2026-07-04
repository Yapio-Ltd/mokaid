defmodule MokaidWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :mokaid

  @session_options [
    store: :cookie,
    key: "_mokaid_key",
    signing_salt: "mokaid_sess",
    same_site: "Lax"
  ]

  socket "/socket", MokaidWeb.UserSocket,
    websocket: [connect_info: [:peer_data, :x_headers]],
    longpoll: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: 50_000_000

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug Corsica,
    origins: {MokaidWeb.Cors, :allowed_origin?, []},
    allow_headers: ["authorization", "content-type", "x-workspace-id"],
    allow_credentials: true,
    max_age: 600

  plug MokaidWeb.Router
end
