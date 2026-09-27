defmodule Mokaid.AvatarWorkerConfigTest do
  use ExUnit.Case, async: false

  setup do
    values = %{
      "DATABASE_URL" => "ecto://fixture:fixture@localhost/fixture",
      "SECRET_KEY_BASE" => String.duplicate("fixture", 12),
      "COGNITO_USER_POOL_ID" => "fixture",
      "COGNITO_CLIENT_ID" => "fixture",
      "S3_BUCKET_UPLOADS" => "fixture-uploads",
      "S3_BUCKET_PRIVATE" => "fixture-private",
      "S3_BUCKET_OUTPUTS" => "fixture-outputs",
      "S3_BUCKET_EXPORTS" => "fixture-exports",
      "AI_WORKER_TOKEN" => "fixture",
      "MOKAID_AVATAR_WORKER_MODE" => nil,
      "MOKAID_AVATAR_PIPELINE_ENABLED" => nil,
      "PHX_SERVER" => "false"
    }

    previous = Map.new(values, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(values, &put_env/1)
    on_exit(fn -> Enum.each(previous, &put_env/1) end)
    :ok
  end

  defp put_env({key, nil}), do: System.delete_env(key)
  defp put_env({key, value}), do: System.put_env(key, value)

  defp config do
    Config.Reader.merge(
      Config.Reader.read!("config/config.exs", env: :prod, target: :host),
      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    )[:mokaid]
  end

  test "production API never consumes avatar jobs and paid creation is off by default" do
    settings = config()
    assert settings[:avatar_worker_mode] == :api
    assert settings[:avatar_pipeline_enabled] == false

    assert settings[Oban][:queues] == [
             default: 10,
             ingestion: 5,
             ai_dispatch: 10,
             notifications: 10,
             billing: 3
           ]

    assert settings[MokaidWeb.Endpoint][:server] == false
    assert Enum.any?(settings[Oban][:plugins], fn {plugin, _} -> plugin == Oban.Plugins.Cron end)
  end

  test "dedicated worker has only one avatar slot, no cron and no HTTP listener" do
    System.put_env("MOKAID_AVATAR_WORKER_MODE", "worker")
    System.put_env("MOKAID_AVATAR_PIPELINE_ENABLED", "true")
    System.put_env("PHX_SERVER", "true")
    settings = config()
    assert settings[:avatar_pipeline_enabled]
    assert settings[Oban][:queues] == [avatars: 1]
    assert settings[Oban][:plugins] == false
    assert settings[Oban][:shutdown_grace_period] == 110_000
    assert settings[MokaidWeb.Endpoint][:server] == false
  end

  test "API HTTP server requires true, not the presence of a false string" do
    System.put_env("MOKAID_AVATAR_WORKER_MODE", "api")
    refute config()[MokaidWeb.Endpoint][:server]
    System.put_env("PHX_SERVER", "true")
    assert config()[MokaidWeb.Endpoint][:server]
  end

  test "invalid worker mode fails closed" do
    System.put_env("MOKAID_AVATAR_WORKER_MODE", "both")
    assert_raise RuntimeError, ~r/MOKAID_AVATAR_WORKER_MODE/, &config/0
  end

  test "an unset PHX_SERVER keeps mix phx.server's local startup behavior" do
    System.delete_env("PHX_SERVER")
    System.delete_env("MOKAID_AVATAR_WORKER_MODE")
    runtime = Config.Reader.read!("config/runtime.exs", env: :dev, target: :host)[:mokaid]
    refute Keyword.has_key?(runtime[MokaidWeb.Endpoint] || [], :server)
    assert runtime[Oban][:queues][:avatars] == 1
  end
end
