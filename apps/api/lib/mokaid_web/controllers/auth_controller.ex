defmodule MokaidWeb.AuthController do
  use MokaidWeb, :controller

  alias Mokaid.Accounts
  alias Mokaid.Auth.Token
  alias Mokaid.Workspaces
  alias MokaidWeb.JSON, as: Serializer

  def login(conn, %{"email" => email, "password" => password}) do
    with {:ok, user} <- Accounts.authenticate_by_password(email, password) do
      _ =
        Accounts.record_login_event(user,
          ip_address: format_ip(conn.remote_ip),
          user_agent: conn |> get_req_header("user-agent") |> List.first(),
          auth_method: "password"
        )

      json(conn, %{
        token: Token.sign(user.id),
        user: Serializer.user(user)
      })
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "bad_request", message: "email and password are required"}})
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(other), do: other && to_string(other)

  def logout(conn, _params) do
    json(conn, %{ok: true})
  end

  @doc """
  Self-serve registration (dev fallback auth mode only — production signups
  go through Cognito). Creates the user, their first workspace and returns
  a session token so the onboarding can start immediately.
  """
  def register(
        conn,
        %{"email" => email, "password" => password, "full_name" => full_name} = params
      ) do
    if Application.get_env(:mokaid, :auth)[:mode] == :dev_fallback do
      workspace_name =
        case String.trim(params["workspace_name"] || "") do
          "" -> "#{full_name |> String.split() |> List.first()}'s Workspace"
          name -> name
        end

      with {:ok, user} <-
             Accounts.register_user(%{
               "email" => email,
               "password" => password,
               "full_name" => full_name
             }),
           {:ok, workspace} <-
             Workspaces.create_workspace(
               %{"name" => workspace_name, "slug" => generate_slug(workspace_name)},
               user
             ) do
        conn
        |> put_status(:created)
        |> json(%{
          token: Token.sign(user.id),
          user: Serializer.user(user),
          workspace: Serializer.workspace(workspace)
        })
      end
    else
      {:error, :registration_disabled}
    end
  end

  def register(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{code: "bad_request", message: "email, password and full_name are required"}
    })
  end

  defp generate_slug(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{base}-#{suffix}"
  end

  def me(conn, _params) do
    user = current_user(conn)
    workspaces = Workspaces.list_workspaces_with_role(user.id)

    json(conn, %{
      user: Serializer.user(user),
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

    with {:ok, _user} <- Accounts.change_password(user, params) do
      json(conn, %{ok: true})
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
    json(conn, %{data: %{configured: Mokaid.Auth.Google.configured?()}})
  end

  @doc "Starts Google sign-in / sign-up. Body: redirect_uri, optional intent (login|signup)."
  def google_start(conn, params) do
    redirect_uri = params["redirect_uri"]
    intent = params["intent"] || "login"

    with {:ok, url} <- Mokaid.Auth.Google.authorize_url(redirect_uri, intent: intent) do
      json(conn, %{data: %{authorize_url: url}})
    end
  end

  @doc """
  Completes Google sign-in / sign-up.
  Body: code, state, redirect_uri.
  """
  def google_callback(conn, %{"code" => code, "state" => state, "redirect_uri" => redirect_uri}) do
    with {:ok, profile} <- Mokaid.Auth.Google.exchange_code(code, state, redirect_uri),
         {:ok, user, status, workspace} <- Accounts.login_or_register_with_google(profile) do
      workspaces = Workspaces.list_workspaces_with_role(user.id)

      payload = %{
        token: Token.sign(user.id),
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
      error: %{code: "bad_request", message: "code, state and redirect_uri are required"}
    })
  end
end
