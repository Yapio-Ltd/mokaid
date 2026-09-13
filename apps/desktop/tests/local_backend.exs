# Run only through MIX_ENV=test mix run --no-start; see local_backend.md.
# This public fixture password is intentionally not a production credential.
defmodule Mokaid.Desktop.LocalBackend.DisabledHTTP do
  @behaviour ExAws.Request.HttpClient
  @impl true
  def request(_method, _url, _body, _headers, _options),
    do: {:error, %{reason: :desktop_local_validation_outbound_http_disabled}}

  def req(request),
    do: {request, RuntimeError.exception("Outbound HTTP disabled for desktop local validation")}
end

defmodule Mokaid.Desktop.LocalBackend do
  @web "http://127.0.0.1:5178"
  @api "http://127.0.0.1:4002"
  @email "desktop.validation@example.invalid"
  @password "Desktop-Fixture-Only-2026!"
  @name "Desktop Local Validation (SYNTHETIC)"
  @slug "desktop-local-validation-fixture"

  def run do
    database_url = validate_environment!()
    configure(database_url)

    if System.argv() == ["--check"] do
      IO.puts("LOCAL_BACKEND_GUARDS_OK (no database connection or fixture writes)")
    else
      if System.argv() != [], do: refuse!("Only --check is supported")
      {:ok, _} = Application.ensure_all_started(:mokaid)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Mokaid.Repo, :auto)
      verify_database!()
      verify_outbound_guards!()
      {user, workspace} = create_fixture!()

      IO.puts("LOCAL_BACKEND_READY pid=#{System.pid()} api=#{@api} browser=#{@web}")
      IO.puts("SYNTHETIC_FIXTURE email=#{@email} user_id=#{user.id} workspace_id=#{workspace.id}")

      IO.puts(
        "Oban manual; queues/plugins disabled; outbound providers blocked; no tokens logged"
      )

      Process.sleep(:infinity)
    end
  end

  defp validate_environment! do
    unless System.get_env("MIX_ENV") == "test" and Mix.env() == :test,
      do: refuse!("MIX_ENV=test is required")

    if Process.whereis(Mokaid.Repo) || Process.whereis(MokaidWeb.Endpoint),
      do: refuse!("Application already started; use mix run --no-start")

    database_url =
      System.get_env("DATABASE_URL") || refuse!("An explicit DATABASE_URL is required")

    uri = URI.parse(database_url)

    unless uri.scheme in ["ecto", "postgres", "postgresql"] and uri.host == "127.0.0.1" and
             uri.port == 55437 and uri.userinfo == "mokaid" and is_nil(uri.query) and
             is_nil(uri.fragment) and is_binary(uri.path) and
             Regex.match?(~r{\A/[a-z][a-z0-9_]*_test\z}, uri.path),
           do:
             refuse!(
               "Only mokaid on numeric loopback port 55437 with a *_test database is allowed"
             )

    unless System.get_env("DESKTOP_AUTH_WEB_BASE_URL", @web) == @web,
      do: refuse!("Browser origin must be the isolated 127.0.0.1:5178 origin")

    database_url
  end

  defp configure(database_url) do
    # Replace, do not merge, database options: no inherited socket/host/connect options.
    Application.put_env(:mokaid, Mokaid.Repo,
      url: database_url,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 8,
      types: Mokaid.PostgrexTypes,
      ssl: false,
      log: false,
      show_sensitive_data_on_connection_error: false
    )

    endpoint = Application.fetch_env!(:mokaid, MokaidWeb.Endpoint)

    Application.put_env(
      :mokaid,
      MokaidWeb.Endpoint,
      Keyword.merge(endpoint,
        server: true,
        http: [ip: {127, 0, 0, 1}, port: 4002],
        url: [scheme: "http", host: "127.0.0.1", port: 4002],
        check_origin: [@web]
      )
    )

    oban = Application.fetch_env!(:mokaid, Oban)

    Application.put_env(
      :mokaid,
      Oban,
      Keyword.merge(oban, testing: :manual, queues: false, plugins: false)
    )

    Application.put_env(:mokaid, :desktop_auth, web_base_url: @web)
    Application.put_env(:mokaid, :cors_origins, [@web])
    Application.put_env(:mokaid, :auth, mode: :dev_fallback)
    Application.put_env(:mokaid, :ai_worker, dispatch: :none, url: nil, token: nil)
    Application.put_env(:mokaid, :imap_probe_enabled, false)
    Application.put_env(:mokaid, :auto_seed_mcp_catalog, false)
    Application.put_env(:mokaid, :auto_seed_assets_3d, false)
    Application.put_env(:mokaid, :assets_cdn_url, "")

    for provider <- [
          :figma_oauth,
          :google_oauth,
          :google_auth,
          :github_oauth,
          :linear_oauth,
          :slack_oauth,
          :microsoft_oauth,
          :notion_oauth,
          :gmail_pubsub,
          :provider_costs
        ] do
      Application.put_env(:mokaid, provider, [])
    end

    Application.put_env(:mokaid, :resend, api_key: nil, from: "fixture@example.invalid")

    Application.put_env(:mokaid, :stripe,
      secret_key: nil,
      publishable_key: nil,
      webhook_secret: nil,
      currency: "usd",
      api_base_url: @api,
      web_base_url: @web
    )

    Application.put_env(:mokaid, :storage, bucket_uploads: "desktop-local-validation-disabled")
    Application.put_env(:ex_aws, :access_key_id, "desktop-local-fixture-disabled")
    Application.put_env(:ex_aws, :secret_access_key, "desktop-local-fixture-disabled")
    Application.put_env(:ex_aws, :http_client, Mokaid.Desktop.LocalBackend.DisabledHTTP)
    Application.put_env(:ex_aws, :retries, max_attempts: 0)

    for service <- [:s3, :sqs, :sts, :cost_explorer, :cloudwatch_logs] do
      Application.put_env(:ex_aws, service,
        scheme: "http://",
        host: "127.0.0.1",
        port: 9,
        region: "us-east-1"
      )
    end

    Req.default_options(adapter: &Mokaid.Desktop.LocalBackend.DisabledHTTP.req/1, retry: false)
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    Application.put_env(:opentelemetry, :processors, [])
    Logger.configure(level: :warning)
  end

  defp verify_database! do
    # Verify the actual peer/database before any mutation, not only the URL parser.
    %{rows: [[database, host, port]]} =
      Ecto.Adapters.SQL.query!(
        Mokaid.Repo,
        "SELECT current_database(), host(inet_server_addr()), inet_server_port()",
        []
      )

    unless Regex.match?(~r/\A[a-z][a-z0-9_]*_test\z/, database) and host == "127.0.0.1" and
             port == 55437,
           do: refuse!("Connected database does not match the isolated test boundary")
  end

  defp verify_outbound_guards! do
    # These calls terminate inside the refusing adapters; no network connection.
    {:error, %RuntimeError{}} = Req.get("https://example.invalid/outbound-guard")

    {:error, %{reason: :desktop_local_validation_outbound_http_disabled}} =
      Mokaid.Desktop.LocalBackend.DisabledHTTP.request(
        :get,
        "https://example.invalid",
        "",
        [],
        []
      )

    %{testing: :manual, queues: [], plugins: []} = Oban.config()
  end

  defp create_fixture! do
    {:ok, result} =
      Mokaid.Repo.transaction(fn ->
        user =
          case Mokaid.Accounts.get_user_by_email(@email) do
            nil ->
              {:ok, created} =
                Mokaid.Accounts.register_user(%{
                  email: @email,
                  full_name: @name,
                  password: @password
                })

              created

            existing ->
              unless existing.full_name == @name and existing.is_platform_admin == false and
                       Mokaid.Accounts.User.active?(existing) and
                       Mokaid.Accounts.User.valid_password?(existing, @password),
                     do: refuse!("Existing fixture account differs; refusing to overwrite")

              existing
          end

        workspace =
          case Mokaid.Repo.get_by(Mokaid.Workspaces.Workspace, slug: @slug) do
            nil ->
              {:ok, created} =
                Mokaid.Workspaces.create_workspace(
                  %{
                    "name" => @name,
                    "slug" => @slug,
                    "description" => "Synthetic local desktop validation only"
                  },
                  user,
                  bootstrap: false
                )

              created

            existing ->
              member =
                Enum.any?(
                  Mokaid.Workspaces.list_workspaces_for_user(user.id),
                  &(&1.id == existing.id)
                )

              unless existing.name == @name and member,
                do: refuse!("Existing fixture workspace differs; refusing to overwrite")

              existing
          end

        {user, workspace}
      end)

    result
  end

  defp refuse!(message), do: raise("LOCAL_BACKEND_REFUSED: " <> message)
end

Mokaid.Desktop.LocalBackend.run()
