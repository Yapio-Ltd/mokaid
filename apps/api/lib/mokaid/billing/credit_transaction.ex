defmodule Mokaid.Billing.CreditTransaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "credit_transactions" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :run, Mokaid.Tasks.TaskExecutionRun
    belongs_to :agent, Mokaid.Agents.Agent

    # spend | plan_grant | purchase | auto_recharge | adjustment
    field :kind, :string
    field :amount, :integer
    field :cost_cents, :integer, default: 0
    field :balance_after, :integer, default: 0
    field :description, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(txn, attrs) do
    txn
    |> cast(attrs, [
      :workspace_id,
      :run_id,
      :agent_id,
      :kind,
      :amount,
      :cost_cents,
      :balance_after,
      :description,
      :metadata
    ])
    |> validate_required([:workspace_id, :kind, :amount])
    |> validate_inclusion(:kind, ~w(spend plan_grant purchase auto_recharge adjustment))
  end
end
