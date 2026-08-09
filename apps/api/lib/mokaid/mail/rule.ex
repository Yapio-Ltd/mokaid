defmodule Mokaid.Mail.Rule do
  @moduledoc """
  A natural-language mail analysis rule: "notify me whenever an invoice
  arrives", "flag anything urgent from my boss".

  The AI worker evaluates every incoming email against the active rules and
  reports matches; matched rules trigger their `action` (in-app notification,
  email alert via Resend, or a simple label).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @actions ~w(notify notify_email label)

  schema "mail_rules" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :mail_account, Mokaid.Mail.Account
    belongs_to :created_by_member, Mokaid.Members.Member

    field :name, :string
    field :prompt, :string
    field :action, :string, default: "notify"
    field :enabled, :boolean, default: true
    field :last_matched_at, :utc_datetime_usec
    field :matches_count, :integer, default: 0

    timestamps()
  end

  def actions, do: @actions

  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :workspace_id,
      :mail_account_id,
      :created_by_member_id,
      :name,
      :prompt,
      :action,
      :enabled
    ])
    |> validate_required([:workspace_id, :name, :prompt])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_length(:prompt, min: 3, max: 2000)
    |> validate_inclusion(:action, @actions)
  end

  def matched_changeset(rule, now) do
    change(rule, last_matched_at: now, matches_count: (rule.matches_count || 0) + 1)
  end
end
