import Config

if System.get_env("PHX_SERVER") do
  config :mokaid, MokaidWeb.Endpoint, server: true
end

# Figma OAuth credentials come from the environment (AWS Secrets Manager in
# deployed environments, .env locally) — never from the repo.
config :mokaid, :figma_oauth,
  client_id: System.get_env("FIGMA_CLIENT_ID"),
  client_secret: System.get_env("FIGMA_CLIENT_SECRET"),
  redirect_uris:
    Enum.uniq([
      System.get_env("FIGMA_REDIRECT_URI") || "https://mokaid.com/oauth/figma/callback",
      "https://mokaid.com/oauth/figma/callback",
      "http://localhost:5173/oauth/figma/callback"
    ])

config :mokaid, :google_oauth,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
  redirect_uris:
    Enum.uniq([
      System.get_env("GOOGLE_REDIRECT_URI") || "https://mokaid.com/oauth/google/callback",
      "https://mokaid.com/oauth/google/callback",
      "http://localhost:5173/oauth/google/callback"
    ])

# Google identity (sign in / sign up) — same client, distinct redirect URIs.
config :mokaid, :google_auth,
  redirect_uris:
    Enum.uniq([
      System.get_env("GOOGLE_AUTH_REDIRECT_URI") || "https://mokaid.com/auth/google/callback",
      "https://mokaid.com/auth/google/callback",
      "http://localhost:5173/auth/google/callback"
    ])

config :mokaid, :github_oauth,
  client_id: System.get_env("GITHUB_CLIENT_ID"),
  client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
  redirect_uris:
    Enum.uniq([
      System.get_env("GITHUB_REDIRECT_URI") || "https://mokaid.com/oauth/github/callback",
      "https://mokaid.com/oauth/github/callback",
      "http://localhost:5173/oauth/github/callback"
    ])

config :mokaid, :linear_oauth,
  client_id: System.get_env("LINEAR_CLIENT_ID"),
  client_secret: System.get_env("LINEAR_CLIENT_SECRET"),
  redirect_uris:
    Enum.uniq([
      System.get_env("LINEAR_REDIRECT_URI") || "https://mokaid.com/oauth/linear/callback",
      "https://mokaid.com/oauth/linear/callback",
      "http://localhost:5173/oauth/linear/callback"
    ])

config :mokaid, :slack_oauth,
  client_id: System.get_env("SLACK_CLIENT_ID"),
  client_secret: System.get_env("SLACK_CLIENT_SECRET"),
  signing_secret: System.get_env("SLACK_SIGNING_SECRET"),
  verification_token: System.get_env("SLACK_VERIFICATION_TOKEN"),
  app_id: System.get_env("SLACK_APP_ID"),
  redirect_uris:
    Enum.uniq([
      System.get_env("SLACK_REDIRECT_URI") || "https://mokaid.com/oauth/slack/callback",
      "https://mokaid.com/oauth/slack/callback",
      "http://localhost:5173/oauth/slack/callback"
    ])

config :mokaid, :microsoft_oauth,
  client_id: System.get_env("MICROSOFT_CLIENT_ID"),
  client_secret: System.get_env("MICROSOFT_CLIENT_SECRET"),
  tenant: System.get_env("MICROSOFT_TENANT") || "common",
  redirect_uris:
    Enum.uniq([
      System.get_env("MICROSOFT_REDIRECT_URI") || "https://mokaid.com/oauth/microsoft/callback",
      "https://mokaid.com/oauth/microsoft/callback",
      "http://localhost:5173/oauth/microsoft/callback"
    ])

config :mokaid, :resend,
  api_key: System.get_env("RESEND_API_KEY"),
  from: System.get_env("RESEND_FROM") || "mokaid <notifications@mokaid.com>"

# GCP Pub/Sub topic used by Gmail users.watch push notifications.
config :mokaid, :gmail_pubsub,
  topic: System.get_env("GMAIL_PUBSUB_TOPIC"),
  audience: System.get_env("GMAIL_PUBSUB_AUDIENCE")

config :mokaid, :notion_oauth,
  client_id: System.get_env("NOTION_CLIENT_ID"),
  client_secret: System.get_env("NOTION_CLIENT_SECRET"),
  redirect_uris:
    Enum.uniq([
      System.get_env("NOTION_REDIRECT_URI") || "https://mokaid.com/auth/notion/callback",
      "https://mokaid.com/auth/notion/callback",
      "http://localhost:5173/auth/notion/callback"
    ])

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing"

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing"

  host = System.get_env("PHX_HOST") || "app.mokaid.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :mokaid, Mokaid.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: true,
    ssl_opts: [verify: :verify_none],
    types: Mokaid.PostgrexTypes

  config :mokaid, MokaidWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0},
      port: port,
      http_1_options: [max_header_length: 65_536, max_request_line_length: 65_536]
    ],
    secret_key_base: secret_key_base

  config :mokaid, :cors_origins, String.split(System.get_env("CORS_ORIGINS", ""), ",", trim: true)

  config :mokaid, :assets_cdn_url, System.get_env("ASSETS_CDN_URL") || ""

  auth_mode =
    case System.get_env("AUTH_MODE", "cognito") do
      "dev_fallback" -> :dev_fallback
      _ -> :cognito
    end

  config :mokaid, :auth,
    mode: auth_mode,
    cognito_region: System.get_env("COGNITO_REGION") || "il-central-1",
    cognito_user_pool_id: System.fetch_env!("COGNITO_USER_POOL_ID"),
    cognito_client_id: System.fetch_env!("COGNITO_CLIENT_ID")

  config :mokaid, :storage,
    adapter: :s3,
    bucket_uploads: System.fetch_env!("S3_BUCKET_UPLOADS"),
    bucket_private: System.fetch_env!("S3_BUCKET_PRIVATE"),
    bucket_outputs: System.fetch_env!("S3_BUCKET_OUTPUTS"),
    bucket_exports: System.fetch_env!("S3_BUCKET_EXPORTS")

  config :mokaid, :ai_worker,
    dispatch: :sqs,
    sqs_queue_url: System.get_env("AI_DISPATCH_QUEUE_URL"),
    url: System.get_env("AI_WORKER_URL"),
    token: System.fetch_env!("AI_WORKER_TOKEN")

  aws_region = System.get_env("AWS_REGION", "il-central-1")

  config :ex_aws,
    region: aws_region

  # ex_aws cannot resolve hosts for il-* regions (its partition regex only
  # covers us|eu|af|ap|sa|ca|me), so service hosts must be set explicitly.
  config :ex_aws, :sqs,
    scheme: "https://",
    region: aws_region,
    host: "sqs.#{aws_region}.amazonaws.com"

  config :ex_aws, :s3,
    scheme: "https://",
    region: aws_region,
    host: "s3.#{aws_region}.amazonaws.com"
end

# Dev/docker: honour AI_WORKER_URL so the API container can reach the
# ai-worker service (http://ai-worker:8100) instead of localhost.
# Never override test.exs — tests force dispatch: :none.
if config_env() == :dev do
  if worker_url = System.get_env("AI_WORKER_URL") do
    config :mokaid, :ai_worker,
      dispatch: :http,
      url: worker_url,
      token: System.get_env("AI_WORKER_TOKEN") || "dev-worker-token"
  end
end

# Stripe payments — API keys come from the environment (AWS Secrets
# Manager in deployed environments, .env locally); never from the repo.
config :mokaid, :stripe,
  secret_key: System.get_env("STRIPE_SECRET_KEY"),
  publishable_key: System.get_env("STRIPE_PUBLISHABLE_KEY"),
  webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET"),
  currency: System.get_env("STRIPE_CURRENCY", "usd"),
  api_base_url: System.get_env("API_BASE_URL", "https://api.mokaid.com"),
  web_base_url: System.get_env("WEB_BASE_URL", "https://mokaid.com")

# Provider Admin keys for cost/usage sync (platform CRM). Distinct from
# worker inference keys — never use sk-admin / sk-ant-admin for chat.
config :mokaid, :provider_costs,
  openai_admin_api_key: System.get_env("OPENAI_ADMIN_API_KEY"),
  anthropic_admin_api_key: System.get_env("ANTHROPIC_ADMIN_API_KEY"),
  aws_region: System.get_env("AWS_REGION", "il-central-1"),
  cost_explorer_region: System.get_env("AWS_CE_REGION", "us-east-1"),
  project_tag: System.get_env("MOKAID_COST_TAG_PROJECT", "mokaid"),
  log_groups:
    String.split(
      System.get_env(
        "MOKAID_LOG_GROUPS",
        "/ecs/mokaid-prod-api,/ecs/mokaid-prod-ai-worker,/ecs/mokaid-prod-crm"
      ),
      ",",
      trim: true
    )
