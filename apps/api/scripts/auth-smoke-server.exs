# Isolated local fixture for apps/web/scripts/auth-smoke.mjs.
if Mix.env() != :test, do: raise("The auth smoke server requires MIX_ENV=test")
database = URI.parse(System.fetch_env!("DATABASE_URL"))

if database.host != "127.0.0.1" or not String.ends_with?(database.path || "", "_auth_smoke"),
  do: raise("Use an isolated loopback database whose name ends in _auth_smoke")

endpoint = Application.fetch_env!(:mokaid, MokaidWeb.Endpoint)

Application.put_env(
  :mokaid,
  MokaidWeb.Endpoint,
  Keyword.merge(endpoint,
    server: true,
    http: [ip: {127, 0, 0, 1}, port: 4017],
    url: [scheme: "http", host: "127.0.0.1", port: 4017],
    check_origin: ["http://127.0.0.1:5177"]
  )
)

Application.put_env(:mokaid, :cors_origins, ["http://127.0.0.1:5177"])
Application.put_env(:mokaid, :desktop_auth, web_base_url: "http://127.0.0.1:5177")
{:ok, _} = Application.ensure_all_started(:mokaid)
Logger.configure(level: :warning)
Process.sleep(:infinity)
