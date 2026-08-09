defmodule Mokaid.Mail.Message do
  @moduledoc "A synced email message with its AI analysis."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  # Keep bodies bounded so a huge newsletter can't bloat the table.
  @max_body_length 20_000

  schema "mail_messages" do
    belongs_to :mail_account, Mokaid.Mail.Account
    belongs_to :workspace, Mokaid.Workspaces.Workspace

    field :provider_message_id, :string
    field :thread_id, :string
    field :from_name, :string
    field :from_email, :string
    field :to_emails, {:array, :string}, default: []
    field :cc_emails, {:array, :string}, default: []
    field :subject, :string
    field :snippet, :string
    field :body_text, :string
    field :folder, :string
    field :labels, {:array, :string}, default: []
    field :has_attachments, :boolean, default: false
    field :received_at, :utc_datetime_usec

    field :ai_importance, :integer
    field :ai_category, :string
    field :ai_summary, :string
    field :matched_rule_ids, {:array, :binary_id}, default: []
    field :analyzed_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :mail_account_id,
      :workspace_id,
      :provider_message_id,
      :thread_id,
      :from_name,
      :from_email,
      :to_emails,
      :cc_emails,
      :subject,
      :snippet,
      :body_text,
      :folder,
      :labels,
      :has_attachments,
      :received_at,
      :ai_importance,
      :ai_category,
      :ai_summary,
      :matched_rule_ids,
      :analyzed_at
    ])
    |> validate_required([:mail_account_id, :workspace_id, :provider_message_id])
    |> validate_number(:ai_importance,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> truncate_body()
    |> unique_constraint([:mail_account_id, :provider_message_id])
  end

  defp truncate_body(changeset) do
    case get_change(changeset, :body_text) do
      body when is_binary(body) and byte_size(body) > @max_body_length ->
        put_change(changeset, :body_text, binary_part(body, 0, @max_body_length))

      _ ->
        changeset
    end
  end
end
