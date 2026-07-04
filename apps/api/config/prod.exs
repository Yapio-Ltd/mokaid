import Config

# Production runtime configuration lives in runtime.exs and is sourced
# from AWS Secrets Manager / SSM Parameter Store via ECS task definitions.

config :logger, level: :info
