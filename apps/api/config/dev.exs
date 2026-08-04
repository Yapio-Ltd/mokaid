import Config

config :mokaid, Mokaid.Repo,
  username: System.get_env("PGUSER", "mokaid"),
  password: System.get_env("PGPASSWORD", "mokaid_dev_password"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: System.get_env("PGDATABASE", "mokaid_dev"),
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10,
  types: Mokaid.PostgrexTypes

config :mokaid, MokaidWeb.Endpoint,
  http: [
    ip: {0, 0, 0, 0},
    port: String.to_integer(System.get_env("PORT", "4000")),
    # Large localhost cookies (other apps on :5173/:4000) exceed Bandit's
    # default 10 KB per-header limit and reject the WebSocket upgrade.
    http_1_options: [max_header_length: 65_536, max_request_line_length: 65_536]
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    System.get_env(
      "SECRET_KEY_BASE",
      "dev_secret_key_base_change_me_dev_secret_key_base_change_me_1234567890"
    ),
  server: true

config :mokaid, :cors_origins, [
  "http://localhost:5173",
  "http://localhost:4173",
  "http://localhost:3001",
  "http://127.0.0.1:3001"
]

config :ex_aws, :s3,
  scheme: "http://",
  host: System.get_env("S3_HOST", "localhost"),
  port: 9000,
  access_key_id: System.get_env("S3_ACCESS_KEY_ID", "mokaid"),
  secret_access_key: System.get_env("S3_SECRET_ACCESS_KEY", "mokaid_dev_password"),
  region: "us-east-1"

config :logger, level: :debug

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
