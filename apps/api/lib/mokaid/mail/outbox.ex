defmodule Mokaid.Mail.Outbox do
  @moduledoc "Durable send claim. A claimed request is never submitted to a provider twice."
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "mail_outbox" do
    field :workspace_id, :binary_id
    field :member_id, :binary_id
    field :account_id, :binary_id
    field :request_id, Ecto.UUID
    field :request_hash, :binary, redact: true
    field :status, :string
    field :error, :string
    field :message_id, :binary_id
    field :provider_message_id, :string
    field :encrypted_attachments, :binary, redact: true
    timestamps()
  end
end
