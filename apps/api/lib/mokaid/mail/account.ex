defmodule Mokaid.Mail.Account do
  @moduledoc """
  A connected mailbox: Gmail (Google OAuth), Microsoft (Graph OAuth) or a
  classic IMAP/SMTP server.

  OAuth-backed accounts reference the workspace `integration_connections` row
  holding the tokens; IMAP accounts carry their own Vault-encrypted password.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @providers ~w(gmail microsoft imap)
  @statuses ~w(active paused error)

  schema "mail_accounts" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :member, Mokaid.Members.Member
    belongs_to :connection, Mokaid.Integrations.IntegrationConnection

    field :provider, :string
    field :email_address, :string
    field :display_name, :string
    field :encrypted_credentials, :binary
    field :settings, :map, default: %{}
    field :status, :string, default: "active"
    field :error_message, :string
    field :sync_state, :map, default: %{}
    field :watch_expires_at, :utc_datetime_usec
    field :subscription_id, :string
    field :subscription_expires_at, :utc_datetime_usec
    field :last_sync_at, :utc_datetime_usec

    timestamps()
  end

  def providers, do: @providers

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :workspace_id,
      :member_id,
      :connection_id,
      :provider,
      :email_address,
      :display_name,
      :settings,
      :status,
      :error_message,
      :sync_state,
      :watch_expires_at,
      :subscription_id,
      :subscription_expires_at,
      :last_sync_at
    ])
    |> validate_required([:workspace_id, :member_id, :provider, :email_address])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:status, @statuses)
    |> update_change(:email_address, &String.downcase(String.trim(&1)))
    |> validate_format(:email_address, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> unique_constraint([:workspace_id, :provider, :email_address])
  end
end
