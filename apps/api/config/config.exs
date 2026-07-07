import Config

config :mokaid,
  ecto_repos: [Mokaid.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

config :mokaid, Mokaid.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_foreign_key: [column: :id, type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

config :mokaid, MokaidWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: MokaidWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Mokaid.PubSub

config :mokaid, Oban,
  engine: Oban.Engines.Basic,
  repo: Mokaid.Repo,
  queues: [default: 10, ingestion: 5, ai_dispatch: 10, notifications: 10, billing: 3],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 * * *", Mokaid.Billing.Workers.UsageAggregationWorker},
       {"0 3 * * *", Mokaid.Billing.Workers.CreditRenewalWorker},
       {"*/15 * * * *", Mokaid.Tasks.Workers.OverdueTaskWorker},
       {"*/5 * * * *", Mokaid.Tasks.Workers.StaleRunWorker}
     ]}
  ]

config :mokaid, :auth,
  mode: :dev_fallback,
  cognito_region: nil,
  cognito_user_pool_id: nil,
  cognito_client_id: nil

config :mokaid, :storage,
  adapter: :s3,
  bucket_uploads: "mokaid-user-uploads-dev",
  bucket_private: "mokaid-private-files-dev",
  bucket_outputs: "mokaid-generated-outputs-dev",
  bucket_exports: "mokaid-exports-dev"

config :mokaid, :ai_worker,
  dispatch: :http,
  url: "http://localhost:8100",
  token: "dev-worker-token"

# PayMe hosted payments. seller_id empty => payments disabled (dev fallback
# activates plans/credits directly). Overridden per env / runtime.exs.
config :mokaid, :payme,
  seller_id: nil,
  sandbox: true,
  currency: "USD",
  api_base_url: "http://localhost:4000",
  web_base_url: "http://localhost:5173"

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 2, cleanup_interval_ms: 60_000 * 10]}

config :ex_aws,
  json_codec: Jason

config :jason, :encoder, escape: :json

config :phoenix, :json_library, Jason

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :trace_id, :workspace_id]

import_config "#{config_env()}.exs"
