defmodule MokaidWeb.FallbackController do
  use Phoenix.Controller, formats: [:json]

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          # Cast errors carry non-string values like `type: {:array, :map}`.
          String.replace(acc, "%{#{key}}", stringify(value))
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "validation_error", message: "Validation failed", details: errors}})
  end

  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{code: "forbidden", message: "You do not have permission for this action"}})
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Resource not found"}})
  end

  def call(conn, {:error, :invalid_credentials}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{code: "invalid_credentials", message: "Invalid email or password"}})
  end

  def call(conn, {:error, :inactive}) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: %{
        code: "account_inactive",
        message: "Account is suspended, banned, or scheduled for deletion"
      }
    })
  end

  def call(conn, {:error, {:token_exchange_failed, _, _}}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{
      error: %{code: "token_exchange_failed", message: "Google token exchange failed"}
    })
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: to_string(reason), message: humanize(reason)}})
  end

  def call(conn, nil) do
    call(conn, {:error, :not_found})
  end

  defp humanize(:office_full), do: "All 9 office desks are occupied"
  defp humanize(:agent_limit_reached), do: "Your plan's AI employee limit has been reached"
  defp humanize(:insufficient_credits), do: "Not enough AI credits for this action"
  defp humanize(:cannot_target_self), do: "You cannot perform this action on your own account"
  defp humanize(:cannot_demote_self), do: "You cannot demote your own platform admin status"
  defp humanize(:last_platform_admin), do: "Cannot remove or ban the last platform admin"
  defp humanize(:amount_too_large), do: "Credit adjustment amount is too large"
  defp humanize(:no_subscription), do: "Workspace has no billing subscription"
  defp humanize(:invalid_password), do: "Password must be at least 10 characters"

  defp humanize(:mcp_integration_limit_reached),
    do: "Your plan's MCP integration limit has been reached — upgrade to connect more"

  defp humanize(:same_workspace), do: "The agent already belongs to this workspace"

  defp humanize(:only_ai_agents_transferable),
    do: "Only AI agents can be copied to another workspace"

  defp humanize(:agent_in_training), do: "Wait for the agent to finish training before copying it"

  defp humanize(:level_too_low),
    do: "Agents must reach level 10 before they can be listed on the marketplace"

  defp humanize(:connect_incomplete),
    do: "Finish Stripe Connect onboarding before publishing a listing"

  defp humanize(:seller_connect_incomplete),
    do: "This seller cannot receive payments yet"

  defp humanize(:listing_already_open), do: "This agent already has an open marketplace listing"
  defp humanize(:own_listing), do: "You cannot purchase your own listing"
  defp humanize(:price_too_low), do: "Price must be at least 1.00 in the listing currency"
  defp humanize(:invalid_country), do: "Provide a valid two-letter country code"
  defp humanize(:stripe_disabled), do: "Stripe payments are not configured"
  defp humanize(:only_ai_agents), do: "Only AI agents can be listed on the marketplace"
  defp humanize(:invalid_mode), do: "Choose sale or rent"
  defp humanize(:invalid_rent_billing), do: "Choose a monthly subscription or a fixed rental term"
  defp humanize(:invalid_fixed_days), do: "Fixed rentals must be 7, 30, or 90 days"

  defp humanize(:not_a_member_of_target_workspace),
    do: "You are not a member of the destination workspace"

  defp humanize(:invalid_archetype), do: "Unknown agent archetype"
  defp humanize(:invalid_boost), do: "Unknown agent boost"
  defp humanize(:empty_request), do: "Add an instruction or at least one file to this mission"

  defp humanize(:no_agent_assigned),
    do: "Choose an employee or create one before starting this mission"

  defp humanize(:agent_unavailable), do: "This employee is unavailable; choose another employee"

  defp humanize(:invalid_attachments),
    do: "Some attachments are unavailable; remove them or upload them again"

  defp humanize(:request_id_conflict),
    do:
      "This confirmation was already used for a different mission; analyze the updated request again"

  defp humanize(:invalid_integrations),
    do: "Some integrations are disconnected or unavailable in this workspace"

  defp humanize(:oauth_only),
    do: "Password changes are managed by your identity provider (e.g. Google)"

  defp humanize(:oauth_not_configured), do: "Google sign-in is not configured"
  defp humanize(:invalid_redirect_uri), do: "Invalid OAuth redirect URI"
  defp humanize(:invalid_state), do: "OAuth state is invalid or expired"
  defp humanize(:profile_incomplete), do: "Google did not return a usable profile"
  defp humanize(:profile_fetch_failed), do: "Could not fetch the Google profile"

  defp humanize(reason) do
    reason |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp stringify(value) do
    to_string(value)
  rescue
    Protocol.UndefinedError -> inspect(value)
  end
end
