defmodule MokaidWeb.AuthController do
  use MokaidWeb, :controller

  alias Mokaid.Accounts
  alias MokaidWeb.Plugs.BrowserSession
  alias Mokaid.Auth.Token
  alias Mokaid.Workspaces
  alias MokaidWeb.JSON, as: Serializer
  require Logger

  plug :protect_auth_response

  plug :limit_auth_attempts
       when action in [:login, :register, :google_start, :google_callback, :change_password]

  def login(conn, %{"email" => email, "password" => password} = params) do
    with :ok <- local_auth_enabled(),
         {:ok, user} <- Accounts.authenticate_by_password(email, password) do
      _ =
        Accounts.record_login_event(user,
          ip_address: format_ip(conn.remote_ip),
          user_agent: conn |> get_req_header("user-agent") |> List.first(),
          auth_method: "password"
        )

      {conn, token} = BrowserSession.issue(conn, Token.sign(user.id), params)

      json(conn, %{
        token: token,
        user: Serializer.user(user)
      })
    else
      {:error, reason} ->
        Logger.warning("Password sign-in refused", auth_failure: reason)
        {:error, reason}
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "bad_request", message: "email and password are required"}})
  end

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()

  def logout(conn, _params) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Token.revoke(token)
      _ -> Token.revoke(BrowserSession.token(conn))
    end

    conn |> BrowserSession.clear() |> json(%{ok: true})
  end

  @doc """
  Self-serve registration when local (`dev_fallback`) authentication is configured.
  Creates the user and first workspace atomically, then issues the session.
  """
  def register(
        conn,
        %{"email" => email, "password" => password, "full_name" => full_name} = params
      )
      when is_binary(email) and is_binary(password) and is_binary(full_name) do
    with :ok <- local_auth_enabled(),
         {:ok, workspace_name} <- registration_workspace_name(params),
         {:ok, {user, workspace}} <-
           Accounts.register_with_workspace(
             %{"email" => email, "password" => password, "full_name" => full_name},
             workspace_name
           ) do
      {conn, token} = BrowserSession.issue(conn, Token.sign(user.id), params)

      conn
      |> put_status(:created)
      |> json(%{
        token: token,
        user: Serializer.user(user),
        workspace: Serializer.workspace(workspace)
      })
    end
  end

  def register(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{code: "bad_request", message: "email, password and full_name are required"}
    })
  end

  defp registration_workspace_name(%{"workspace_name" => value})
       when not is_binary(value) and not is_nil(value), do: {:error, :invalid_workspace_name}

  defp registration_workspace_name(params) do
    case String.trim(params["workspace_name"] || "") do
      "" -> {:ok, "#{params["full_name"] |> String.split() |> List.first() || "My"}'s Workspace"}
      name -> {:ok, name}
    end
  end

  defp local_auth_enabled do
    if Application.get_env(:mokaid, :auth)[:mode] == :dev_fallback,
      do: :ok,
      else: {:error, :registration_disabled}
  end

  def me(conn, _params) do
    user = current_user(conn)
    workspaces = Workspaces.list_workspaces_with_role(user.id)

    json(conn, %{
      user: Serializer.user(user),
      client_policy: Mokaid.Auth.ClientPolicy.public_settings(),
      workspaces:
        Enum.map(workspaces, fn {workspace, role_name} ->
          workspace |> Serializer.workspace() |> Map.put(:role_name, role_name)
        end)
    })
  end

  @doc """
  Updates the authenticated user's profile.
  Body (all optional): full_name, locale, timezone.
  """
  def update_me(conn, params) do
    user = current_user(conn)
    attrs = Map.take(params, ["full_name", "locale", "timezone"])

    with {:ok, updated} <- Accounts.update_profile(user, attrs) do
      json(conn, %{user: Serializer.user(updated)})
    end
  end

  @doc "Streams the current user's uploaded avatar (S3 key stored in avatar_url)."
  def avatar(conn, _params) do
    user = current_user(conn)

    with true <- Accounts.User.uploaded_avatar?(user),
         {:ok, body, content_type} <- Mokaid.Storage.get_object(user.avatar_url) do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("cache-control", "private, max-age=300")
      |> send_resp(200, body)
    else
      false ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "No uploaded avatar"}})

      {:error, _} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Avatar file not found"}})
    end
  end

  @doc "Multipart upload for the current user's avatar. Field name: file."
  def upload_avatar(conn, %{"file" => %Plug.Upload{} = file}) do
    user = current_user(conn)

    with :ok <- validate_avatar_file(file),
         {:ok, updated} <- Accounts.upload_avatar(user, file) do
      json(conn, %{user: Serializer.user(updated)})
    else
      {:error, :invalid_image} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "invalid_image", message: "Avatar must be a PNG, JPG, WebP or GIF image"}
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  def upload_avatar(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "missing_file", message: "Expected multipart field \"file\""}})
  end

  def remove_avatar(conn, _params) do
    user = current_user(conn)

    with {:ok, updated} <- Accounts.remove_avatar(user) do
      json(conn, %{user: Serializer.user(updated)})
    end
  end

  @doc """
  Changes the authenticated user's password (email/password accounts only).
  Body: current_password, password, password_confirmation.
  """
  def change_password(conn, params) do
    user = current_user(conn)

    with {:ok, updated} <- Accounts.change_password(user, params) do
      # Password changes invalidate every previous session; issue one replacement
      # for the browser that completed reauthentication.
      {conn, token} = BrowserSession.issue(conn, Token.sign(updated.id), params)
      json(conn, %{ok: true, token: token})
    end
  end

  defp validate_avatar_file(%Plug.Upload{content_type: ct, filename: name}) do
    ext = name |> Path.extname() |> String.downcase()
    ext_ok = ext in ~w(.jpg .jpeg .png .webp .gif)
    type_ok = is_binary(ct) and String.starts_with?(ct, "image/")

    if ext_ok or type_ok, do: :ok, else: {:error, :invalid_image}
  end

  @doc "Returns whether Google identity OAuth is configured."
  def google_status(conn, _params) do
    json(conn, %{
      data: %{configured: local_auth_enabled() == :ok and Mokaid.Auth.Google.configured?()}
    })
  end

  @doc "Starts Google sign-in / sign-up. Body: redirect_uri, optional intent (login|signup)."
  def google_start(conn, params) do
    redirect_uri = params["redirect_uri"]
    intent = params["intent"] || "login"

    with :ok <- local_auth_enabled(),
         {:ok, url} <-
           Mokaid.Auth.Google.authorize_url(redirect_uri,
             intent: intent,
             code_challenge: params["code_challenge"]
           ) do
      json(conn, %{data: %{authorize_url: url}})
    end
  end

  @doc """
  Completes Google sign-in / sign-up.
  Body: code, state, redirect_uri.
  """
  def google_callback(
        conn,
        %{
          "code" => code,
          "state" => state,
          "redirect_uri" => redirect_uri,
          "code_verifier" => verifier
        } = params
      ) do
    with :ok <- local_auth_enabled(),
         {:ok, profile} <- Mokaid.Auth.Google.exchange_code(code, state, redirect_uri, verifier),
         {:ok, user, status, workspace} <- Accounts.login_or_register_with_google(profile) do
      workspaces = Workspaces.list_workspaces_with_role(user.id)

      {conn, token} = BrowserSession.issue(conn, Token.sign(user.id), params)

      payload = %{
        token: token,
        user: Serializer.user(user),
        status: status,
        workspaces:
          Enum.map(workspaces, fn {ws, role_name} ->
            ws |> Serializer.workspace() |> Map.put(:role_name, role_name)
          end)
      }

      payload =
        if workspace do
          Map.put(payload, :workspace, Serializer.workspace(workspace))
        else
          payload
        end

      status_code = if status == :created, do: :created, else: :ok

      conn
      |> put_status(status_code)
      |> json(payload)
    end
  end

  def google_callback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{
        code: "bad_request",
        message: "code, state, redirect_uri and code_verifier are required"
      }
    })
  end

  defp protect_auth_response(conn, _) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp limit_auth_attempts(conn, _) do
    action = action_name(conn)
    limit = if action == :register, do: 5, else: 15
    ip = format_ip(conn.remote_ip)

    case Hammer.check_rate("account-auth:#{action}:#{ip}", 60_000, limit) do
      {:allow, _} ->
        conn

      {:deny, _} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> put_status(:too_many_requests)
        |> json(%{
          error: %{code: "rate_limited", message: "Too many attempts. Try again in a minute."}
        })
        |> halt()

      _ ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: %{
            code: "temporarily_unavailable",
            message: "Sign-in is temporarily unavailable."
          }
        })
        |> halt()
    end
  end
end
