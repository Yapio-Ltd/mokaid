import Config

if System.get_env("PHX_SERVER") do
  config :mokaid, MokaidWeb.Endpoint, server: true
end

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
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  config :mokaid, :cors_origins, String.split(System.get_env("CORS_ORIGINS", ""), ",", trim: true)

  config :mokaid, :auth,
    mode: :cognito,
    cognito_region: System.get_env("COGNITO_REGION") || "eu-west-1",
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

  config :ex_aws,
    region: System.get_env("AWS_REGION", "eu-west-1")
end
