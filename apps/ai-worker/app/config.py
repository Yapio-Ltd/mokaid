from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    phoenix_api_url: str = "http://localhost:4000"
    worker_auth_token: str = "dev-worker-token"
    openai_api_key: str = ""
    openai_model: str = "gpt-4o-mini"

    s3_endpoint: str = "http://localhost:9000"
    s3_access_key_id: str = "mokaid"
    s3_secret_access_key: str = "mokaid_dev_password"

    # SQS consumption (production). Empty in dev: dispatch happens over HTTP.
    ai_runs_queue_url: str = ""
    aws_region: str = ""

    max_steps_per_run: int = 20
    run_timeout_seconds: int = 600


@lru_cache
def get_settings() -> Settings:
    return Settings()
