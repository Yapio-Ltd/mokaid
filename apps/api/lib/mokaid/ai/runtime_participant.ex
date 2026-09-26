defmodule Mokaid.AI.RuntimeParticipant do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "managed_runtime_participants" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :run, Mokaid.Tasks.TaskExecutionRun
    belongs_to :agent, Mokaid.Agents.Agent
    field :participant_id, :string
    field :lease_expires_at, :utc_datetime_usec
    field :released_at, :utc_datetime_usec
    timestamps()
  end
end
