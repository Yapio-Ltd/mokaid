import Config

# Production runtime configuration lives in runtime.exs and is sourced
# from AWS Secrets Manager / SSM Parameter Store via ECS task definitions.

config :logger, level: :info

# HTTPS terminates at the trusted load balancer; always mark browser cookies Secure.
config :mokaid, :secure_browser_cookies, true
