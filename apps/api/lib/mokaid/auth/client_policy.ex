defmodule Mokaid.Auth.ClientPolicy do
  @moduledoc """
  Rollout policy separating browser account management from desktop business use.

  Session metadata is supplied only by `Mokaid.Auth.Session.authenticate/1`, after
  signature, live desktop-session and live-account validation. Request headers,
  user agents, URL parameters and platform-admin roles never establish a client
  type. The policy adds a restriction; it never replaces resource permissions.
  """

  @browser_actions %{
    MokaidWeb.AuthController => [
      :me,
      :update_me,
      :change_password,
      :avatar,
      :upload_avatar,
      :remove_avatar
    ],
    MokaidWeb.DesktopAuthController => [:show, :approve],
    MokaidWeb.WorkspaceController => [:index, :show, :logo],
    MokaidWeb.MemberController => [:index],
    MokaidWeb.BillingController => [
      :overview,
      :invoices,
      :plans,
      :credit_packs,
      :change_plan,
      :checkout,
      :credits_checkout,
      :update_auto_recharge,
      :config,
      :portal
    ],
    MokaidWeb.IntegrationOAuthController => [
      :google_callback,
      :github_callback,
      :linear_callback,
      :slack_callback,
      :notion_callback,
      :microsoft_callback
    ],
    MokaidWeb.MCPOAuthController => [:figma_callback]
  }

  def enabled?, do: Application.get_env(:mokaid, :desktop_only_business, false) == true

  def desktop?(%{desktop_session_id: id, access_expires_at: expires})
      when is_binary(id) and is_integer(expires), do: true

  def desktop?(_), do: false

  def browser_action?(controller, action),
    do: action in Map.get(@browser_actions, controller, [])

  def http_allowed?(metadata, controller, action),
    do: not enabled?() or desktop?(metadata) or browser_action?(controller, action)

  def channels_allowed?(metadata), do: not enabled?() or desktop?(metadata)

  def public_settings, do: %{desktop_only_business: enabled?()}
end
