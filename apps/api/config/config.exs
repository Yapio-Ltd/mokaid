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
       {"30 3 * * *", Mokaid.Billing.Workers.ProviderCostSyncWorker},
       {"45 3 * * *", Mokaid.Billing.Workers.InvoiceCleanupWorker},
       {"0 4 * * *", Mokaid.Billing.Workers.AwsCostSyncWorker},
       {"0 5 * * *", Mokaid.Workers.UserAnonymizationWorker},
       {"0 * * * *", Mokaid.Billing.Workers.SubscriptionRenewalWorker},
       {"15 * * * *", Mokaid.Billing.Workers.MonthlyCreditsWorker},
       {"*/15 * * * *", Mokaid.Tasks.Workers.OverdueTaskWorker},
       {"*/5 * * * *", Mokaid.Tasks.Workers.StaleRunWorker},
       {"* * * * *", Mokaid.Office.Workers.ActivitySchedulerWorker},
       {"* * * * *", Mokaid.AI.Workers.ScheduleWorker},
       {"*/2 * * * *", Mokaid.Mail.Workers.PollWorker},
       {"30 * * * *", Mokaid.Mail.Workers.WatchRenewalWorker}
     ]}
  ]

# Empty = serve relative /assets3d/* from the web origin (public folder / future CF).
config :mokaid, :assets_cdn_url, ""

config :mokaid, :auth,
  mode: :dev_fallback,
  cognito_region: nil,
  cognito_user_pool_id: nil,
  cognito_client_id: nil

config :mokaid, :google_auth,
  redirect_uris: [
    "http://localhost:5173/auth/google/callback",
    "https://mokaid.com/auth/google/callback"
  ]

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

# Stripe payments. Empty secret_key => payments disabled (dev fallback
# activates plans/credits directly). Overridden by runtime.exs / env.
config :mokaid, :stripe,
  secret_key: nil,
  publishable_key: nil,
  webhook_secret: nil,
  currency: "usd",
  api_base_url: "http://localhost:4000",
  web_base_url: "http://localhost:5173"

# Provider cost sync defaults (overridden by runtime.exs / env in prod).
config :mokaid, :provider_costs,
  openai_admin_api_key: nil,
  anthropic_admin_api_key: nil,
  aws_region: "il-central-1",
  cost_explorer_region: "us-east-1",
  project_tag: "mokaid",
  log_groups: []

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
