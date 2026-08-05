import Config

repo_config = [
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  types: Mokaid.PostgrexTypes
]

repo_config =
  case System.get_env("DATABASE_URL") do
    nil ->
      Keyword.merge(repo_config,
        username: System.get_env("PGUSER", "mokaid"),
        password: System.get_env("PGPASSWORD", "mokaid_dev_password"),
        hostname: System.get_env("PGHOST", "localhost"),
        database: "mokaid_test#{System.get_env("MIX_TEST_PARTITION")}"
      )

    database_url ->
      Keyword.put(repo_config, :url, database_url)
  end

config :mokaid, Mokaid.Repo, repo_config

config :mokaid, MokaidWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_test_secret_key_base_test_secret_key_base_12",
  server: false

config :mokaid, Oban, testing: :inline

# Head-start training worker: no cinematic delays in tests (Oban runs inline).
config :mokaid, :boost_training_step_ms, 0

# No AI worker in tests: the dispatcher always uses its deterministic heuristic.
config :mokaid, :ai_worker, dispatch: :none, url: nil, token: "test-token"

config :mokaid, :cors_origins, ["http://localhost:5173"]

# Avoid bulk mcp_servers seed inside list_servers/0 — concurrent Sandbox tests
# deadlock when multiple suites re-insert 90+ catalog rows at once.
config :mokaid, :auto_seed_mcp_catalog, false

config :bcrypt_elixir, :log_rounds, 1

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime
